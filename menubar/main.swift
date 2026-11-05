// MeetRec: menu bar front-end for the `meet` CLI.
// Build: ../build-app.sh  (creates ~/Applications/MeetRec.app)

import AppKit
import ServiceManagement
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser.path
// meet.py and the recorder ship inside the app; outside a bundle (dev runs) fall back to the CLI wrapper
let bundledScript = Bundle.main.resourceURL.map { $0.appendingPathComponent("meet.py").path }
    .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
let bundledCapture = Bundle.main.bundlePath + "/Contents/MacOS/meetrec-capture"
let meetBin = "\(home)/.local/bin/meet"
let stateFile = "\(home)/.local/state/meetrec/current.json"
let configFile = ProcessInfo.processInfo.environment["MEETREC_CONFIG_FILE"] ?? "\(home)/.config/meetrec/config.json"
let appLog = "\(home)/.local/state/meetrec/app.log"

// MARK: - UI language
//
// Strings live in JSON files, one per language (key -> text, "{name}" placeholders):
//   <app>/Contents/Resources/locales/<code>.json   shipped with the app (repo: locales/)
//   ~/.config/meetrec/locales/<code>.json          yours: new languages or overrides, no rebuild
// Missing keys fall back to English, then to the key itself.
// Chosen language: "ui_language" in config.json (default: system language if a file exists).

enum I18n {
    static let userDir = URL(fileURLWithPath: "\(home)/.config/meetrec/locales")
    static var bundleDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("locales") }
    private static var cache: [String: [String: String]] = [:]

    static func read(_ url: URL) -> [String: String] {
        guard let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j.compactMapValues { $0 as? String }
    }

    /// bundle file + user overrides, merged
    static func table(_ code: String) -> [String: String] {
        if let t = cache[code] { return t }
        var t: [String: String] = [:]
        for dir in [bundleDir, userDir].compactMap({ $0 }) {
            t.merge(read(dir.appendingPathComponent("\(code).json"))) { _, new in new }
        }
        cache[code] = t
        return t
    }

    /// languages found on disk: (code, name)
    static func available() -> [(code: String, name: String)] {
        var codes = Set<String>()
        for dir in [bundleDir, userDir].compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for f in files where f.hasSuffix(".json") { codes.insert(String(f.dropLast(5))) }
        }
        return codes.sorted().map { ($0, table($0)["_language_name"] ?? $0) }
    }

    static func reload() { cache = [:] }
}

var uiLang: String = {
    let c = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any]
    if let l = c?["ui_language"] as? String { return l }
    let sys = String((Locale.preferredLanguages.first ?? "en").prefix(2))
    return I18n.available().contains { $0.code == sys } ? sys : "en"
}()

/// Localized string: T("start_recording"), T("login_code_copied", ["code": code])
func T(_ key: String, _ args: [String: String] = [:]) -> String {
    var s = I18n.table(uiLang)[key] ?? I18n.table("en")[key] ?? key
    for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
    return s
}

// MARK: - process helper

func runMeet(_ args: [String], onLine: ((String) -> Void)? = nil,
             completion: @escaping (Int32, String) -> Void) {
    let p = Process()
    var env = ProcessInfo.processInfo.environment
    if let script = bundledScript, let py = findPython() {
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [script] + args
        env["MEETREC_CAPTURE"] = bundledCapture
    } else {
        p.executableURL = URL(fileURLWithPath: meetBin)
        p.arguments = args
    }
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
    @Published var uiLanguages: [(code: String, name: String)] = []
    @Published var micID = ""
    @Published var summary = true
    @Published var keepRaw = false
    @Published var keepTracks = false
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
        I18n.reload()                     // pick up edited/new JSON files
        uiLanguages = I18n.available()
        uiLanguage = uiLang
        micID = raw["mic_id"] as? String ?? ""
        summary = raw["summary"] as? Bool ?? true
        keepRaw = raw["keep_raw"] as? Bool ?? false
        keepTracks = raw["keep_tracks"] as? Bool ?? false
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
        raw["keep_tracks"] = keepTracks
        if let d = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: "\(home)/.config/meetrec", withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: configFile), options: .atomic)
            saved = true
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { loginMessage = T("launch_at_login") + error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func login() {
        loggingIn = true
        loginMessage = T("starting_microsoft_login")
        runMeet(["login"], onLine: { line in
            // MSAL: "To sign in, use a web browser to open the page https://... and enter the code XXXX to authenticate."
            if let urlR = line.range(of: #"https://\S+"#, options: .regularExpression),
               let codeR = line.range(of: #"code ([A-Z0-9]+)"#, options: .regularExpression) {
                let url = String(line[urlR])
                let code = String(line[codeR].dropFirst(5))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                self.loginMessage = T("login_code_copied", ["code": code])
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }) { status, out in
            self.loggingIn = false
            self.loginMessage = status == 0 ? T("logged_in") :
                T("login_failed") + (out.split(separator: "\n").last.map(String.init) ?? "")
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
            Button(T("choose")) {
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
            Section(T("interface")) {
                Picker(T("menu_and_messages_language"), selection: $s.uiLanguage) {
                    ForEach(s.uiLanguages, id: \.code) { l in Text(l.name).tag(l.code) }
                }
                Button(T("open_translations_folder")) {
                    try? FileManager.default.createDirectory(at: I18n.userDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(I18n.userDir)
                }
            }
            Section(T("recordings")) {
                PathField(label: T("audio_folder"), path: $s.recordingsDir)
                Picker(T("microphone"), selection: $s.micID) {
                    Text(T("system_default")).tag("")
                    ForEach(s.mics, id: \.id) { m in Text(m.name).tag(m.id) }
                }
                Picker(T("meeting_language_transcription"), selection: $s.language) {
                    Text("Italiano").tag("it"); Text("English").tag("en")
                }
                Toggle(T("also_keep_raw_audio_much_more_space"), isOn: $s.keepRaw)
                Toggle(T("keep_separate_tracks"), isOn: $s.keepTracks)
            }
            Section("Obsidian") {
                PathField(label: "Vault", path: $s.vault)
                TextField(T("meetings_folder_relative_to_vault"), text: $s.meetingsDir)
                TextField(T("people_folder_relative_to_vault"), text: $s.peopleDir)
                TextField(T("frontmatter_context"), text: $s.context)
                Toggle(T("automatic_summary_with_claude_text_only"), isOn: $s.summary)
            }
            Section(T("outlook_calendar")) {
                LabeledContent("Account", value: s.account)
                HStack {
                    Button(s.loggingIn ? T("waiting_for_the_browser") : T("microsoft_login")) { s.login() }.disabled(s.loggingIn)
                    Button("Logout") { s.logout() }
                }
                if !s.loginMessage.isEmpty { Text(s.loginMessage).font(.callout).textSelection(.enabled) }
            }
            Section(T("system")) {
                Toggle(T("open_meetrec_at_login"), isOn: Binding(get: { s.launchAtLogin }, set: { s.setLaunchAtLogin($0) }))
                HStack {
                    Button(T("microphone_permission")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    Button(T("system_audio_permission")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            HStack {
                Spacer()
                if s.saved { Text(T("saved")).foregroundStyle(.secondary) }
                Button(T("save")) { s.save() }.keyboardShortcut("s").buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        // a grouped Form scrolls and has no intrinsic height: give the window a real size
        .frame(width: 560, height: 1000)
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
    let setup = SetupModel()
    var setupWindow: NSWindow?
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
        if !args.contains("--render-docs") {
            setup.refresh { [weak self] in
                if self?.setup.requiredMissing == true || args.contains("--setup") { self?.openSetup() }
            }
        }
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
            _ = add(c.alive ? T("recording_for") + elapsed(c.start) + t : T("the_recorder_stopped_stop_to_save"), nil)
            _ = add(T("stop_and_process"), #selector(stopAndProcess), key: "s")
            _ = add(T("stop_without_processing"), #selector(stopOnly))
        } else {
            if processing { _ = add(T("processing") + processingStep, nil) }
            _ = add(T("start_recording"), #selector(start), key: "r")
            _ = add(T("start_with_title"), #selector(startWithTitle))
        }
        menu.addItem(.separator())
        if let n = lastNote {
            _ = add(T("open_last_note") + (n as NSString).lastPathComponent, #selector(openLastNote))
        }
        _ = add(T("open_recordings_folder"), #selector(openRecordings))
        if !recover.isEmpty {
            let sub = NSMenu()
            for r in recover {
                let title = "\(r["started_at"] as? String ?? "?") [\(r["duration"] as? String ?? "")] \(r["title"] as? String ?? "")"
                let i = NSMenuItem(title: title, action: processing ? nil : #selector(processDir(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = r["dir"]
                sub.addItem(i)
            }
            let m = add(T("to_process") + " (\(recover.count))", nil)
            m.isEnabled = true; m.submenu = sub
        }
        menu.addItem(.separator())
        _ = add(T("settings"), #selector(openSettings), key: ",")
        _ = add(T("setup_menu"), #selector(openSetup))
        _ = add("Log", #selector(openLog))
        _ = add(T("quit_meetrec"), #selector(quit), key: "q")
        loadRecover()
    }

    // MARK: actions

    @objc func start() { startRecording(title: nil) }

    @objc func startWithTitle() {
        let a = NSAlert()
        a.messageText = T("meeting_title")
        a.informativeText = T("leave_empty_to_use_the_calendar_event")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: T("record")); a.addButton(withTitle: T("cancel"))
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
                a.messageText = T("recording_did_not_start")
                a.informativeText = out.suffix(800) + "\n\n" + T("if_it_is_a_permission_problem_enable")
                a.addButton(withTitle: "OK"); a.addButton(withTitle: T("open_privacy"))
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
        processingStep = T("starting")
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
                notify(T("meeting_saved"), (n as NSString).lastPathComponent)
            } else {
                notify(T("processing_failed"), T("the_audio_is_safe_details_in_log"))
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

    @objc func openSetup() {
        setup.onLogin = { [weak self] in self?.openSettings(); self?.settings.login() }
        setup.refresh()
        if setupWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(m: setup) { [weak self] in
                self?.setupWindow?.close()
            }))
            w.title = "MeetRec – Setup"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            setupWindow = w
        }
        setupWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openSettings() {
        settings.load()
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(s: settings)))
            w.title = "MeetRec – " + T("settings_2")
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 560, height: 1000))
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
            a.messageText = T("a_recording_is_in_progress")
            a.informativeText = T("if_you_quit_the_recording_keeps_going")
            a.addButton(withTitle: T("quit")); a.addButton(withTitle: T("cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        NSApp.terminate(nil)
    }
}

// MARK: - README images, drawn offscreen with demo data: MeetRec --render-docs <dir>

final class FlippedView: NSView { override var isFlipped: Bool { true } }

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
    lv.agcBox.title = T("lower_automatically_when_clipping")
    let panel = NSView(frame: lv.frame)
    panel.appearance = dark
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    panel.layer?.cornerRadius = 10
    panel.addSubview(lv)
    savePNG(panel, dir + "/levels.png")

    // the whole menu: level panel + items, drawn like a dark macOS menu
    let rowH: CGFloat = 24, sepH: CGFloat = 11, pad: CGFloat = 6
    let rows: [(String, String)?] = [
        nil,
        (T("start_recording"), "⌘R"), (T("start_with_title"), ""),
        nil,
        (T("open_last_note") + "2026-11-05 - Weekly.md", ""), (T("open_recordings_folder"), ""),
        (T("to_process") + " (1)", "›"),
        nil,
        (T("settings"), "⌘,"), (T("setup_menu"), ""), ("Log", ""), (T("quit_meetrec"), "⌘Q"),
    ]
    let itemsH = rows.reduce(CGFloat(0)) { $0 + ($1 == nil ? sepH : rowH) }
    let menuView = FlippedView(frame: NSRect(x: 0, y: 0, width: lv.frame.width, height: lv.frame.height + itemsH + pad * 2))
    menuView.appearance = dark
    menuView.wantsLayer = true
    menuView.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    menuView.layer?.cornerRadius = 10
    let lv2 = LevelView()
    lv2.micName = lv.micName; lv2.history = lv.history; lv2.mic = lv.mic; lv2.sys = lv.sys
    lv2.setVolume(0.62); lv2.agcBox.state = .on; lv2.agcBox.title = lv.agcBox.title
    lv2.frame.origin = NSPoint(x: 0, y: pad)
    menuView.addSubview(lv2)
    var y = lv2.frame.maxY
    let font = NSFont.menuFont(ofSize: 13)
    for r in rows {
        guard let (title, key) = r else {
            let sep = NSBox(frame: NSRect(x: 14, y: y + sepH / 2, width: menuView.frame.width - 28, height: 1))
            sep.boxType = .separator
            menuView.addSubview(sep)
            y += sepH
            continue
        }
        let t = NSTextField(labelWithString: title)
        t.font = font; t.textColor = .labelColor
        t.frame = NSRect(x: 16, y: y + 3, width: menuView.frame.width - (key.isEmpty ? 32 : 92), height: 18)
        menuView.addSubview(t)
        if !key.isEmpty {
            let k = NSTextField(labelWithString: key)
            k.font = font; k.textColor = .tertiaryLabelColor; k.alignment = .right
            k.frame = NSRect(x: menuView.frame.width - 76, y: y + 3, width: 60, height: 18)
            menuView.addSubview(k)
        }
        y += rowH
    }
    savePNG(menuView, dir + "/menu.png")

    // settings window (demo config from MEETREC_CONFIG_FILE, demo account)
    let st = Settings()
    st.load()
    st.account = "you@company.com"
    st.mics = [("MacBook Pro Microphone", "BuiltInMicrophoneDevice")]
    let host = NSHostingView(rootView: SettingsView(s: st))
    host.frame = NSRect(x: 0, y: 0, width: 560, height: 1000)
    host.appearance = dark
    let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    win.appearance = dark
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // let SwiftUI lay out
    st.account = "you@company.com"                           // whoami may have answered meanwhile
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    savePNG(host, dir + "/settings.png")

    // menu bar states
    let bar = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 28))
    bar.appearance = dark
    bar.wantsLayer = true
    bar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.white]
    let states: [(NSImage, String, String)] = [
        (d.glyph(fill: nil, level: nil), "", T("ready")),
        (d.glyph(fill: .systemRed, level: -20), " 12:34", T("recording")),
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
