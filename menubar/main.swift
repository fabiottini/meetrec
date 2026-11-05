// MeetRec: menu bar front-end for the `meet` CLI.
// Build: ../build-app.sh  (creates ~/Applications/MeetRec.app)

import AppKit
import ServiceManagement
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser.path
let meetBin = "\(home)/.local/bin/meet"   // wrapper installed by install.sh
let stateFile = "\(home)/.local/state/meetrec/current.json"
let configFile = ProcessInfo.processInfo.environment["MEETREC_CONFIG_FILE"] ?? "\(home)/.config/meetrec/config.json"
let appLog = "\(home)/.local/state/meetrec/app.log"

// MARK: - UI language ("ui_language" in config.json: "it" | "en"; default from the system language)

var uiLang: String = {
    let c = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any]
    if let l = c?["ui_language"] as? String { return l }
    return (Locale.preferredLanguages.first ?? "en").hasPrefix("it") ? "it" : "en"
}()

/// Localized string: L("italiano", "english")
func L(_ it: String, _ en: String) -> String { uiLang == "it" ? it : en }

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
    @Published var uiLanguage = uiLang { didSet { uiLang = uiLanguage } }   // switches the UI at once
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
        uiLanguage = uiLang
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
        raw["ui_language"] = uiLanguage
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
        } catch { loginMessage = L("Avvio al login: ", "Launch at login: ") + error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func login() {
        loggingIn = true
        loginMessage = L("Avvio login Microsoft…", "Starting Microsoft login…")
        runMeet(["login"], onLine: { line in
            // MSAL: "To sign in, use a web browser to open the page https://... and enter the code XXXX to authenticate."
            if let urlR = line.range(of: #"https://\S+"#, options: .regularExpression),
               let codeR = line.range(of: #"code ([A-Z0-9]+)"#, options: .regularExpression) {
                let url = String(line[urlR])
                let code = String(line[codeR].dropFirst(5))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                self.loginMessage = L("Codice \(code) copiato negli appunti: incollalo nella pagina che si è aperta nel browser.", "Code \(code) copied to the clipboard: paste it in the page that opened in your browser.")
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }) { status, out in
            self.loggingIn = false
            self.loginMessage = status == 0 ? L("Login riuscito.", "Logged in.") :
                L("Login non riuscito: ", "Login failed: ") + (out.split(separator: "\n").last.map(String.init) ?? "")
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
            Button(L("Scegli…", "Choose…")) {
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
            Section(L("Interfaccia", "Interface")) {
                Picker(L("Lingua di menu e messaggi", "Menu and messages language"), selection: $s.uiLanguage) {
                    Text("Italiano").tag("it"); Text("English").tag("en")
                }
            }
            Section(L("Registrazioni", "Recordings")) {
                PathField(label: L("Cartella audio", "Audio folder"), path: $s.recordingsDir)
                Picker(L("Microfono", "Microphone"), selection: $s.micID) {
                    Text(L("Predefinito di sistema", "System default")).tag("")
                    ForEach(s.mics, id: \.id) { m in Text(m.name).tag(m.id) }
                }
                Picker(L("Lingua del meeting (trascrizione)", "Meeting language (transcription)"), selection: $s.language) {
                    Text("Italiano").tag("it"); Text("English").tag("en")
                }
                Toggle(L("Tieni anche l'audio grezzo (molto più spazio)", "Also keep raw audio (much more space)"), isOn: $s.keepRaw)
            }
            Section("Obsidian") {
                PathField(label: "Vault", path: $s.vault)
                TextField(L("Cartella meeting (relativa al vault)", "Meetings folder (relative to vault)"), text: $s.meetingsDir)
                TextField(L("Cartella persone (relativa al vault)", "People folder (relative to vault)"), text: $s.peopleDir)
                TextField(L("context nel frontmatter", "frontmatter context"), text: $s.context)
                Toggle(L("Riassunto automatico con Claude (solo testo)", "Automatic summary with Claude (text only)"), isOn: $s.summary)
            }
            Section(L("Calendario Outlook", "Outlook calendar")) {
                LabeledContent("Account", value: s.account)
                HStack {
                    Button(s.loggingIn ? L("In attesa del browser…", "Waiting for the browser…") : L("Login Microsoft", "Microsoft login")) { s.login() }.disabled(s.loggingIn)
                    Button("Logout") { s.logout() }
                }
                if !s.loginMessage.isEmpty { Text(s.loginMessage).font(.callout).textSelection(.enabled) }
            }
            Section(L("Sistema", "System")) {
                Toggle(L("Avvia MeetRec al login", "Open MeetRec at login"), isOn: Binding(get: { s.launchAtLogin }, set: { s.setLaunchAtLogin($0) }))
                HStack {
                    Button(L("Permesso microfono", "Microphone permission")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    Button(L("Permesso audio di sistema", "System audio permission")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            HStack {
                Spacer()
                if s.saved { Text(L("Salvato", "Saved")).foregroundStyle(.secondary) }
                Button(L("Salva", "Save")) { s.save() }.keyboardShortcut("s").buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        // a grouped Form scrolls and has no intrinsic height: give the window a real size
        .frame(width: 560, height: 840)
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
    let levels = LevelController()
    lazy var levelItem: NSMenuItem = {
        let i = NSMenuItem()
        i.view = levels.view
        return i
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        levels.currentDir = { [weak self] in
            guard let c = self?.current(), c.alive else { return nil }
            return c.dir
        }
        levels.config = {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any] ?? [:]
        }
        levels.saveConfig = { c in
            if let d = try? JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: URL(fileURLWithPath: configFile), options: .atomic)
            }
        }
        refresh()
        loadRecover()
        // used to take README screenshots, and handy from a terminal: open -a MeetRec --args --settings
        let args = CommandLine.arguments
        if args.contains("--settings") { openSettings() }
        if args.contains("--open-menu") {
            // pop the same menu at a fixed spot (works even when a menu bar manager hides the icon)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let top = NSScreen.main.map { $0.frame.maxY - 60 } ?? 800
                self.item.menu?.popUp(positioning: nil, at: NSPoint(x: 120, y: top), in: nil)
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { levels.open() }
    func menuDidClose(_ menu: NSMenu) { levels.close() }

    // current recording from the CLI state file (works also if started from the terminal)
    func current() -> (start: Date, title: String?, alive: Bool, dir: String)? {
        guard let d = FileManager.default.contents(atPath: stateFile),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = j["started_at"] as? String, let pid = j["pid"] as? Int,
              let start = ISO8601DateFormatter().date(from: s) else { return nil }
        return (start, j["title"] as? String, kill(pid_t(pid), 0) == 0, j["dir"] as? String ?? "")
    }

    func elapsed(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Menu bar glyph: rounded square with a waveform.
    /// idle/processing: template (follows light/dark menu bar), waveform cut out of a solid tile.
    /// recording: red tile with white bars that follow the real mic level; dead: orange.
    func glyph(fill: NSColor?, level: Double?) -> NSImage {
        let img = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { _ in
            // rounded square ("mini app icon"): distinct from mic glyphs and round VPN/record dots
            let tile = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1, width: 16, height: 16), xRadius: 4.5, yRadius: 4.5)
            (fill ?? .black).setFill()
            tile.fill()

            var heights: [CGFloat] = [3.5, 7.5, 11, 6.5, 3.5]
            if let db = level {            // live: scale the bars with the mic level (-60..0 dB)
                let f = CGFloat(max(0.2, min(1, (db + 55) / 40)))
                heights = heights.map { max(1.6, $0 * f) }
            }
            let w: CGFloat = 1.6, gap: CGFloat = 1.3
            var x = 9.5 - (CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap) / 2
            let cy: CGFloat = 9
            for h in heights {
                let r = NSBezierPath(roundedRect: NSRect(x: x, y: cy - h / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2)
                if fill == nil {
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    NSColor.black.setFill()
                } else {
                    NSColor.white.setFill()
                }
                r.fill()
                x += w + gap
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        img.isTemplate = (fill == nil)
        img.accessibilityDescription = "MeetRec"
        return img
    }

    func refresh() {
        guard let b = item.button else { return }
        if let c = current() {
            let db = LevelController.readLevels(c.dir)["mic"]?.0 ?? -120
            b.image = c.alive ? glyph(fill: .systemRed, level: db) : glyph(fill: .systemOrange, level: nil)
            b.title = " " + elapsed(c.start)
        } else if processing {
            b.image = glyph(fill: nil, level: nil)
            b.title = " …"
        } else {
            b.image = glyph(fill: nil, level: nil)
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
        menu.addItem(levelItem)
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector?, key: String = "", enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self; i.isEnabled = enabled && action != nil
            menu.addItem(i); return i
        }
        if let c = cur {
            let t = c.title.map { " – \($0)" } ?? ""
            _ = add(c.alive ? L("● In registrazione da ", "● Recording for ") + elapsed(c.start) + t : L("⚠︎ Il registratore si è fermato: ferma per salvare", "⚠︎ The recorder stopped: stop to save"), nil)
            _ = add(L("Ferma ed elabora", "Stop and process"), #selector(stopAndProcess), key: "s")
            _ = add(L("Ferma senza elaborare", "Stop without processing"), #selector(stopOnly))
        } else {
            if processing { _ = add(L("Elaborazione: ", "Processing: ") + processingStep, nil) }
            _ = add(L("Avvia registrazione", "Start recording"), #selector(start), key: "r")
            _ = add(L("Avvia con titolo…", "Start with title…"), #selector(startWithTitle))
        }
        menu.addItem(.separator())
        if let n = lastNote {
            _ = add(L("Apri ultima nota: ", "Open last note: ") + (n as NSString).lastPathComponent, #selector(openLastNote))
        }
        _ = add(L("Apri cartella registrazioni", "Open recordings folder"), #selector(openRecordings))
        if !recover.isEmpty {
            let sub = NSMenu()
            for r in recover {
                let title = "\(r["started_at"] as? String ?? "?") [\(r["duration"] as? String ?? "")] \(r["title"] as? String ?? "")"
                let i = NSMenuItem(title: title, action: processing ? nil : #selector(processDir(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = r["dir"]
                sub.addItem(i)
            }
            let m = add(L("Da elaborare", "To process") + " (\(recover.count))", nil)
            m.isEnabled = true; m.submenu = sub
        }
        menu.addItem(.separator())
        _ = add(L("Impostazioni…", "Settings…"), #selector(openSettings), key: ",")
        _ = add("Log", #selector(openLog))
        _ = add(L("Esci da MeetRec", "Quit MeetRec"), #selector(quit), key: "q")
        loadRecover()
    }

    // MARK: actions

    @objc func start() { startRecording(title: nil) }

    @objc func startWithTitle() {
        let a = NSAlert()
        a.messageText = L("Titolo del meeting", "Meeting title")
        a.informativeText = L("Lascia vuoto per usare il titolo dell'evento in calendario.", "Leave empty to use the calendar event title.")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: L("Registra", "Record")); a.addButton(withTitle: L("Annulla", "Cancel"))
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
                a.messageText = L("La registrazione non è partita", "Recording did not start")
                a.informativeText = out.suffix(800) + "\n\n" + L("Se è un problema di permessi, abilita MeetRec in Privacy > Microfono e Registrazione schermo e audio di sistema, poi riavvia MeetRec.", "If it is a permission problem, enable MeetRec in Privacy > Microphone and Screen & System Audio Recording, then restart MeetRec.")
                a.addButton(withTitle: "OK"); a.addButton(withTitle: L("Apri Privacy", "Open Privacy"))
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
        processingStep = L("avvio", "starting")
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
                notify(L("Meeting salvato", "Meeting saved"), (n as NSString).lastPathComponent)
            } else {
                notify(L("Elaborazione non riuscita", "Processing failed"), L("L'audio è salvo. Dettagli in Log, riprova da \"Da elaborare\".", "The audio is safe. Details in Log, retry from \"To process\"."))
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
            w.title = "MeetRec – " + L("Impostazioni", "Settings")
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 560, height: 840))
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
            a.messageText = L("C'è una registrazione in corso", "A recording is in progress")
            a.informativeText = L("Se esci, la registrazione continua lo stesso in background. Potrai fermarla riaprendo MeetRec o con `meet stop`.", "If you quit, the recording keeps going in the background. Stop it by reopening MeetRec or with `meet stop`.")
            a.addButton(withTitle: L("Esci", "Quit")); a.addButton(withTitle: L("Annulla", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        NSApp.terminate(nil)
    }
}

// MARK: - README images, drawn offscreen with demo data: MeetRec --render-docs <dir>

func savePNG(_ view: NSView, _ path: String, scale: CGFloat = 2) {
    let size = view.bounds.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

func renderDocs(_ dir: String, _ d: AppDelegate) {
    let dark = NSAppearance(named: .darkAqua)!
    NSAppearance.current = dark

    // level panel
    let lv = LevelView()
    lv.micName = "MacBook Pro Microphone"
    lv.history = (0..<90).map { i in
        let t = Double(i)
        return i % 23 < 4 ? -70 : -27 + 9 * sin(t / 2.3) + 4 * sin(t * 1.7)
    }
    lv.mic = (-21, -8)
    lv.sys = (-25, -11)
    lv.setVolume(0.62)
    lv.agcBox.state = .on
    lv.agcBox.title = L("Riduci automaticamente se satura", "Lower automatically when clipping")
    let panel = NSView(frame: lv.frame)
    panel.appearance = dark
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    panel.layer?.cornerRadius = 10
    panel.addSubview(lv)
    savePNG(panel, dir + "/levels.png")

    // menu bar states
    let bar = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 28))
    bar.appearance = dark
    bar.wantsLayer = true
    bar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.white]
    let states: [(NSImage, String, String)] = [
        (d.glyph(fill: nil, level: nil), "", L("pronto", "ready")),
        (d.glyph(fill: .systemRed, level: -20), " 12:34", L("registra", "recording")),
    ]
    var x: CGFloat = 10
    for (img, title, caption) in states {
        let iv = NSImageView(frame: NSRect(x: x, y: 5, width: 19, height: 18))
        img.isTemplate = false
        if title.isEmpty {   // template glyph: tint it white like the real menu bar does
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
            }
            iv.image = tinted
        } else { iv.image = img }
        bar.addSubview(iv)
        let tf = NSTextField(labelWithAttributedString: NSAttributedString(string: title, attributes: attrs))
        tf.frame = NSRect(x: x + 20, y: 5, width: 60, height: 18)
        if !title.isEmpty { bar.addSubview(tf) }
        let cap = NSTextField(labelWithString: caption)
        cap.font = .systemFont(ofSize: 10); cap.textColor = .secondaryLabelColor
        cap.frame = NSRect(x: x + (title.isEmpty ? 26 : 74), y: 6, width: 60, height: 14)
        bar.addSubview(cap)
        x += title.isEmpty ? 90 : 150
    }
    savePNG(bar, dir + "/menubar.png")
}

let app = NSApplication.shared
let delegate = AppDelegate()
if let i = CommandLine.arguments.firstIndex(of: "--render-docs"), i + 1 < CommandLine.arguments.count {
    renderDocs(CommandLine.arguments[i + 1], delegate)
    exit(0)
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
