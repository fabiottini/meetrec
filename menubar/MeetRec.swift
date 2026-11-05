// MeetRec: menu bar front-end for the `meet` CLI.
// Build: ../build-app.sh  (creates ~/Applications/MeetRec.app)

import AppKit
import ServiceManagement
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser.path
let meetBin = "\(home)/.local/bin/meet"   // wrapper installed by install.sh
let stateFile = "\(home)/.local/state/meetrec/current.json"
let configFile = "\(home)/.config/meetrec/config.json"
let appLog = "\(home)/.local/state/meetrec/app.log"

// MARK: - process helper

func runMeet(_ args: [String], onLine: ((String) -> Void)? = nil,
             completion: @escaping (Int32, String) -> Void) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: meetBin)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["PYTHONUNBUFFERED"] = "1"
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    var output = ""
    var partial = ""
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { h in
        let data = h.availableData
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); output += s; partial += s
        var lines: [String] = []
        while let r = partial.range(of: "\n") {
            lines.append(String(partial[..<r.lowerBound])); partial = String(partial[r.upperBound...])
        }
        lock.unlock()
        appendLog(s)
        for l in lines { DispatchQueue.main.async { onLine?(l) } }
    }
    p.terminationHandler = { proc in
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        if let s = String(data: rest, encoding: .utf8) { output += s; appendLog(s) }
        let out = output
        lock.unlock()
        DispatchQueue.main.async { completion(proc.terminationStatus, out) }
    }
    do { try p.run() } catch { completion(-1, "cannot run \(meetBin): \(error)") }
}

func appendLog(_ s: String) {
    let url = URL(fileURLWithPath: appLog)
    if !FileManager.default.fileExists(atPath: appLog) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: appLog, contents: nil)
    }
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); try? h.close() }
}

func notify(_ title: String, _ body: String) {
    let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    try? p.run()
}

func openObsidian(_ notePath: String) {
    var c = URLComponents(string: "obsidian://open")!
    c.queryItems = [URLQueryItem(name: "path", value: notePath)]
    if let u = c.url { NSWorkspace.shared.open(u) }
}

// MARK: - settings model

final class Settings: ObservableObject {
    @Published var recordingsDir = ""
    @Published var vault = ""
    @Published var meetingsDir = ""
    @Published var peopleDir = ""
    @Published var context = ""
    @Published var language = "it"
    @Published var micID = ""
    @Published var summary = true
    @Published var keepRaw = false
    @Published var mics: [(name: String, id: String)] = []
    @Published var account = "…"
    @Published var loginMessage = ""
    @Published var loggingIn = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var saved = false

    var raw: [String: Any] = [:]

    func load() {
        raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any] ?? [:]
        recordingsDir = raw["recordings_dir"] as? String ?? "\(home)/Recordings/meetings"
        vault = raw["vault"] as? String ?? ""
        meetingsDir = raw["meetings_dir"] as? String ?? ""
        peopleDir = raw["people_dir"] as? String ?? ""
        context = raw["context"] as? String ?? "work"
        language = raw["language"] as? String ?? "it"
        micID = raw["mic_id"] as? String ?? ""
        summary = raw["summary"] as? Bool ?? true
        keepRaw = raw["keep_raw"] as? Bool ?? false
        launchAtLogin = SMAppService.mainApp.status == .enabled
        saved = false
        loadMics()
        refreshAccount()
    }

    func loadMics() {
        runMeet(["mics"]) { _, out in
            self.mics = out.split(separator: "\n").compactMap { line in
                let parts = line.dropFirst(2).split(separator: "\t")
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }
        }
    }

    func refreshAccount() {
        account = "…"
        runMeet(["whoami"]) { _, out in self.account = out.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func save() {
        raw["recordings_dir"] = recordingsDir
        raw["vault"] = vault
        raw["meetings_dir"] = meetingsDir
        raw["people_dir"] = peopleDir
        raw["context"] = context
        raw["language"] = language
        raw["mic_id"] = micID.isEmpty ? NSNull() : micID
        raw["summary"] = summary
        raw["keep_raw"] = keepRaw
        if let d = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: "\(home)/.config/meetrec", withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: configFile), options: .atomic)
            saved = true
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { loginMessage = "Avvio al login: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func login() {
        loggingIn = true
        loginMessage = "Avvio login Microsoft…"
        runMeet(["login"], onLine: { line in
            // MSAL: "To sign in, use a web browser to open the page https://... and enter the code XXXX to authenticate."
            if let urlR = line.range(of: #"https://\S+"#, options: .regularExpression),
               let codeR = line.range(of: #"code ([A-Z0-9]+)"#, options: .regularExpression) {
                let url = String(line[urlR])
                let code = String(line[codeR].dropFirst(5))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                self.loginMessage = "Codice \(code) copiato negli appunti: incollalo nella pagina che si è aperta nel browser."
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }) { status, out in
            self.loggingIn = false
            self.loginMessage = status == 0 ? "Login riuscito." :
                "Login non riuscito: " + (out.split(separator: "\n").last.map(String.init) ?? "")
            self.refreshAccount()
        }
    }

    func logout() {
        runMeet(["logout"]) { _, _ in self.loginMessage = ""; self.refreshAccount() }
    }
}

struct PathField: View {
    let label: String
    @Binding var path: String
    var body: some View {
        HStack {
            TextField(label, text: $path)
            Button("Scegli…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                p.directoryURL = URL(fileURLWithPath: path)
                NSApp.activate(ignoringOtherApps: true)
                if p.runModal() == .OK, let u = p.url { path = u.path }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var s: Settings
    var body: some View {
        Form {
            Section("Registrazioni") {
                PathField(label: "Cartella audio", path: $s.recordingsDir)
                Picker("Microfono", selection: $s.micID) {
                    Text("Predefinito di sistema").tag("")
                    ForEach(s.mics, id: \.id) { m in Text(m.name).tag(m.id) }
                }
                Picker("Lingua", selection: $s.language) {
                    Text("Italiano").tag("it"); Text("English").tag("en")
                }
                Toggle("Tieni anche l'audio grezzo (molto più spazio)", isOn: $s.keepRaw)
            }
            Section("Obsidian") {
                PathField(label: "Vault", path: $s.vault)
                TextField("Cartella meeting (relativa al vault)", text: $s.meetingsDir)
                TextField("Cartella persone (relativa al vault)", text: $s.peopleDir)
                TextField("context nel frontmatter", text: $s.context)
                Toggle("Riassunto automatico con Claude (solo testo)", isOn: $s.summary)
            }
            Section("Calendario Outlook") {
                LabeledContent("Account", value: s.account)
                HStack {
                    Button(s.loggingIn ? "In attesa del browser…" : "Login Microsoft") { s.login() }.disabled(s.loggingIn)
                    Button("Logout") { s.logout() }
                }
                if !s.loginMessage.isEmpty { Text(s.loginMessage).font(.callout).textSelection(.enabled) }
            }
            Section("Sistema") {
                Toggle("Avvia MeetRec al login", isOn: Binding(get: { s.launchAtLogin }, set: { s.setLaunchAtLogin($0) }))
                HStack {
                    Button("Permesso microfono") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    Button("Permesso audio di sistema") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            HStack {
                Spacer()
                if s.saved { Text("Salvato").foregroundStyle(.secondary) }
                Button("Salva") { s.save() }.keyboardShortcut("s").buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        // a grouped Form scrolls and has no intrinsic height: give the window a real size
        .frame(width: 560, height: 700)
        .padding(.bottom, 8)
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    var processing = false
    var processingStep = ""
    var lastNote: String? = UserDefaults.standard.string(forKey: "lastNote")
    var recover: [[String: Any]] = []
    var settingsWindow: NSWindow?
    let settings = Settings()

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        loadRecover()
    }

    // current recording from the CLI state file (works also if started from the terminal)
    func current() -> (start: Date, title: String?, alive: Bool)? {
        guard let d = FileManager.default.contents(atPath: stateFile),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = j["started_at"] as? String, let pid = j["pid"] as? Int,
              let start = ISO8601DateFormatter().date(from: s) else { return nil }
        return (start, j["title"] as? String, kill(pid_t(pid), 0) == 0)
    }

    func elapsed(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    func refresh() {
        guard let b = item.button else { return }
        if let c = current() {
            let img = NSImage(systemSymbolName: c.alive ? "record.circle.fill" : "exclamationmark.triangle.fill",
                              accessibilityDescription: "MeetRec")
            img?.isTemplate = false
            b.image = img?.withSymbolConfiguration(.init(paletteColors: [c.alive ? .systemRed : .systemOrange]))
            b.title = " " + elapsed(c.start)
        } else if processing {
            b.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MeetRec")
            b.title = " …"
        } else {
            b.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "MeetRec")
            b.title = ""
        }
        b.imagePosition = .imageLeading
    }

    func loadRecover() {
        runMeet(["recover", "--json"]) { _, out in
            if let d = out.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { self.recover = arr }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cur = current()
        func add(_ title: String, _ action: Selector?, key: String = "", enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self; i.isEnabled = enabled && action != nil
            menu.addItem(i); return i
        }
        if let c = cur {
            let t = c.title.map { " – \($0)" } ?? ""
            _ = add(c.alive ? "● In registrazione da \(elapsed(c.start))\(t)" : "⚠︎ Il registratore si è fermato: ferma per salvare", nil)
            _ = add("Ferma ed elabora", #selector(stopAndProcess), key: "s")
            _ = add("Ferma senza elaborare", #selector(stopOnly))
        } else {
            if processing { _ = add("Elaborazione: \(processingStep)", nil) }
            _ = add("Avvia registrazione", #selector(start), key: "r")
            _ = add("Avvia con titolo…", #selector(startWithTitle))
        }
        menu.addItem(.separator())
        if let n = lastNote {
            _ = add("Apri ultima nota: \((n as NSString).lastPathComponent)", #selector(openLastNote))
        }
        _ = add("Apri cartella registrazioni", #selector(openRecordings))
        if !recover.isEmpty {
            let sub = NSMenu()
            for r in recover {
                let title = "\(r["started_at"] as? String ?? "?") [\(r["duration"] as? String ?? "")] \(r["title"] as? String ?? "")"
                let i = NSMenuItem(title: title, action: processing ? nil : #selector(processDir(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = r["dir"]
                sub.addItem(i)
            }
            let m = add("Da elaborare (\(recover.count))", nil)
            m.isEnabled = true; m.submenu = sub
        }
        menu.addItem(.separator())
        _ = add("Impostazioni…", #selector(openSettings), key: ",")
        _ = add("Log", #selector(openLog))
        _ = add("Esci da MeetRec", #selector(quit), key: "q")
        loadRecover()
    }

    // MARK: actions

    @objc func start() { startRecording(title: nil) }

    @objc func startWithTitle() {
        let a = NSAlert()
        a.messageText = "Titolo del meeting"
        a.informativeText = "Lascia vuoto per usare il titolo dell'evento in calendario."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Registra"); a.addButton(withTitle: "Annulla")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn {
            let t = f.stringValue.trimmingCharacters(in: .whitespaces)
            startRecording(title: t.isEmpty ? nil : t)
        }
    }

    func startRecording(title: String?) {
        var args = ["start"]
        if let t = title { args += ["-t", t] }
        runMeet(args) { status, out in
            self.refresh()
            if status != 0 {
                let a = NSAlert()
                a.messageText = "La registrazione non è partita"
                a.informativeText = out.suffix(800) + "\n\nSe è un problema di permessi, abilita MeetRec in Privacy > Microfono e Registrazione schermo e audio di sistema, poi riavvia MeetRec."
                a.addButton(withTitle: "OK"); a.addButton(withTitle: "Apri Privacy")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }

    @objc func stopAndProcess() { runPipeline(["stop"]) }
    @objc func stopOnly() { runMeet(["stop", "--no-process"]) { _, _ in self.refresh(); self.loadRecover() } }
    @objc func processDir(_ sender: NSMenuItem) {
        if let d = sender.representedObject as? String { runPipeline(["process", d]) }
    }

    func runPipeline(_ args: [String]) {
        processing = true
        processingStep = "avvio"
        refresh()
        var note: String?
        runMeet(args, onLine: { line in
            let l = line.replacingOccurrences(of: "[meet] ", with: "")
            if l.hasPrefix("note: ") { note = String(l.dropFirst(6)) }
            if !l.hasPrefix(" ") { self.processingStep = l }
        }) { status, out in
            self.processing = false
            self.refresh()
            self.loadRecover()
            if status == 0, let n = note {
                self.lastNote = n
                UserDefaults.standard.set(n, forKey: "lastNote")
                notify("Meeting salvato", (n as NSString).lastPathComponent)
            } else {
                notify("Elaborazione non riuscita", "L'audio è salvo. Dettagli in Log, riprova da \"Da elaborare\".")
            }
        }
    }

    @objc func openLastNote() { if let n = lastNote { openObsidian(n) } }
    @objc func openRecordings() {
        settings.load()
        try? FileManager.default.createDirectory(atPath: settings.recordingsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: settings.recordingsDir))
    }
    @objc func openLog() {
        appendLog("")
        NSWorkspace.shared.open(URL(fileURLWithPath: appLog))
    }

    @objc func openSettings() {
        settings.load()
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(s: settings)))
            w.title = "MeetRec – Impostazioni"
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 560, height: 700))
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func quit() {
        if let c = current(), c.alive {
            let a = NSAlert()
            a.messageText = "C'è una registrazione in corso"
            a.informativeText = "Se esci, la registrazione continua lo stesso in background. Potrai fermarla riaprendo MeetRec o con `meet stop`."
            a.addButton(withTitle: "Esci"); a.addButton(withTitle: "Annulla")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
