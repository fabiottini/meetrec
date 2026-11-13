// MeetRec: menu bar front-end for the `meet` CLI.
// Build: ../build-app.sh  (creates ~/Applications/MeetRec.app)

import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import Carbon.HIToolbox

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

@discardableResult
func runMeet(_ args: [String], onLine: ((String) -> Void)? = nil,
             completion: @escaping (Int32, String) -> Void) -> Process {
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
        if data.isEmpty { h.readabilityHandler = nil; return }      // EOF: stop, do not spin
        guard let s = String(data: data, encoding: .utf8) else { return }
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
    return p
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

// MARK: - global shortcut Control-Option-Command-R: start, or stop and process, from any app

final class HotKey {
    static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ h: @escaping () -> Void) {
        handler = h
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D524543), id: 1)      // 'MREC'
        let st = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey | controlKey), id,
                                     GetApplicationEventTarget(), 0, &ref)
        appendLog("[app] global shortcut ⌃⌥⌘R " + (st == noErr ? "registered" : "NOT registered (\(st)): used by another app?") + "\n")
    }
}

/// shorten a menu title with "…" in the middle so the menu stays as wide as the level panel
/// (a long note name made the menu wider and left an empty area next to the panel)
func fitMenuTitle(_ title: String, room: CGFloat) -> String {
    let font = NSFont.menuFont(ofSize: 0)
    func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
    guard width(title) > room else { return title }
    // measure the result WITH the ellipsis, so a shortened title never needs a second cut
    func join(_ c: [Character]) -> String {
        let mid = c.count / 2
        return String(c[..<mid]).trimmingCharacters(in: .whitespaces) + "…" + String(c[mid...]).trimmingCharacters(in: .whitespaces)
    }
    var chars = Array(title)
    while chars.count > 6 && width(join(chars)) > room {
        chars.remove(at: chars.count / 2)                      // keep the start and the end
    }
    return join(chars)
}

// MARK: - config.json, read again only when the file changes (it is polled by the timers)

final class Config {
    static let shared = Config()
    private var cached: [String: Any] = [:]
    private var mtime: Date?

    var value: [String: Any] {
        let m = (try? FileManager.default.attributesOfItem(atPath: configFile))?[.modificationDate] as? Date
        if m != mtime || mtime == nil {
            mtime = m
            cached = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any] ?? [:]
        }
        return cached
    }
}

// MARK: - voice profiles (filters are in meet.py)

let voiceProfiles: [(String, String)] = [("none", "voice_none"), ("p1", "voice_p1"), ("p2", "voice_p2"),
                                         ("p3", "voice_p3"), ("p4", "voice_p4")]

/// record a few seconds from the mic and play original + profile
func voiceTest(_ profile: String) {
    guard profile != "none" else { return }
    notify("MeetRec", T("voice_test_speak"))
    runMeet(["voice-test", profile], onLine: { line in
        if line.contains("Bluetooth") { notify("MeetRec", T("voice_test_bt")) }
    }) { _, _ in }
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
    @Published var callPrompt = true
    @Published var recordSystem = true
    @Published var transcriptMode = "separate"
    @Published var voiceProfile = "none"
    @Published var voiceScope = "mine"
    @Published var afterAudio = "ask"
    @Published var mics: [(name: String, id: String)] = []
    @Published var account = "…"
    @Published var loginMessage = ""
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
        callPrompt = raw["call_prompt"] as? Bool ?? true
        recordSystem = raw["record_system"] as? Bool ?? true
        transcriptMode = raw["transcript_mode"] as? String ?? "separate"
        voiceProfile = raw["voice_profile"] as? String ?? "none"
        voiceScope = raw["voice_profile_scope"] as? String ?? "mine"
        afterAudio = raw["after_process_audio"] as? String ?? "ask"
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
        raw["call_prompt"] = callPrompt
        raw["record_system"] = recordSystem
        raw["transcript_mode"] = transcriptMode
        raw["voice_profile"] = voiceProfile
        raw["voice_profile_scope"] = voiceScope
        raw["after_process_audio"] = afterAudio
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
                Toggle(T("call_prompt_setting"), isOn: $s.callPrompt)
            }
            Section(T("audio_section")) {
                Picker(T("what_to_record"), selection: $s.recordSystem) {
                    Text(T("record_both")).tag(true); Text(T("record_mine")).tag(false)
                }
                Picker(T("transcript_kind"), selection: $s.transcriptMode) {
                    Text(T("transcript_separate")).tag("separate"); Text(T("transcript_mixed")).tag("mixed")
                }
                Picker(T("voice_profile"), selection: $s.voiceProfile) {
                    ForEach(voiceProfiles, id: \.0) { v in Text(T(v.1)).tag(v.0) }
                }
                if s.voiceProfile != "none" {
                    Picker(T("voice_scope"), selection: $s.voiceScope) {
                        Text(T("voice_scope_mine")).tag("mine"); Text(T("voice_scope_all")).tag("all")
                    }
                    HStack {
                        Text(T("voice_test_info")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(T("voice_test")) { voiceTest(s.voiceProfile) }
                    }
                }
                Picker(T("after_audio"), selection: $s.afterAudio) {
                    Text(T("after_audio_ask")).tag("ask"); Text(T("after_audio_keep")).tag("keep")
                    Text(T("after_audio_delete")).tag("delete")
                }
            }
            Section("Obsidian") {
                PathField(label: "Vault", path: $s.vault)
                TextField(T("meetings_folder_relative_to_vault"), text: $s.meetingsDir)
                TextField(T("people_folder_relative_to_vault"), text: $s.peopleDir)
                TextField(T("frontmatter_context"), text: $s.context)
                Toggle(T("automatic_summary_with_claude_text_only"), isOn: $s.summary)
            }
            Section(T("cal_title")) {
                Text(s.account.isEmpty ? T("cal_none") : s.account).textSelection(.enabled)
                Button(T("cal_manage")) { NotificationCenter.default.post(name: .init("MeetRecOpenSetup"), object: nil) }
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
        .frame(width: 560)
        .frame(minHeight: 500, maxHeight: .infinity)
        .padding(.bottom, 8)
    }
}

// MARK: - app

/// target for the radio buttons of the "which meeting?" dialog (NSAlert has no radio group)
final class RadioTarget: NSObject {
    static let shared = RadioTarget()
    var onClick: ((NSButton) -> Void)?
    @objc func clicked(_ b: NSButton) { onClick?(b) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {

    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === setupWindow { setup.cancelLogin() }
    }

    var item: NSStatusItem!
    var timer: Timer?
    var processing = false
    var processingStep = ""
    var lastNote: String? = UserDefaults.standard.string(forKey: "lastNote")
    var recover: [[String: Any]] = []
    var recent: [[String: Any]] = []           // processed recordings, for "Recordings" (edit afterwards)
    var settingsWindow: NSWindow?
    let settings = Settings()
    let setup = SetupModel()
    let calls = CallWatcher()
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
        scheduleTimer()
        levels.currentDir = { [weak self] in
            guard let c = self?.current(), c.alive else { return nil }
            return c.dir
        }
        levels.config = { Config.shared.value }
        levels.onMute = { [weak self] in self?.toggleMute() }
        levels.saveConfig = { c in
            if let d = try? JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: URL(fileURLWithPath: configFile), options: .atomic)
            }
        }
        if !MicMute.shared.enabled { MicMute.shared.restoreAll() }
        startCallWatcher()
        HotKey.register { [weak self] in self?.hotKeyPressed() }
        NotificationCenter.default.addObserver(forName: .init("MeetRecOpenSetup"), object: nil, queue: .main) { [weak self] _ in
            self?.openSetup()
        }
        refresh()
        loadRecover()
        // used to take README screenshots, and handy from a terminal: open -a MeetRec --args --settings
        let args = CommandLine.arguments
        if args.contains("--bench-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                var times: [Double] = []
                for _ in 0..<5 {
                    let t0 = Date()
                    let m = NSMenu()
                    self.menuNeedsUpdate(m)
                    self.menuWillOpen(m)
                    times.append(Date().timeIntervalSince(t0) * 1000)
                    self.menuDidClose(m)
                }
                print("menu open (ms): " + times.map { String(format: "%.1f", $0) }.joined(separator: ", "))
                exit(0)
            }
            return
        }
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
    /// set only by --render-docs, to draw the menu of a recording without recording
    var docsRecording: Date?

    func current() -> (start: Date, title: String?, alive: Bool, dir: String)? {
        if let s = docsRecording { return (s, "Weekly product sync", true, "") }
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
    func glyph(fill: NSColor?, level: Double?, muted: Bool = false) -> NSImage {
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
            if muted {                     // mic muted: diagonal slash, with a cut-out border for contrast
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2.5, y: 16.5)); slash.line(to: NSPoint(x: 16.5, y: 1.5))
                slash.lineCapStyle = .round
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                slash.lineWidth = 4.2; NSColor.black.setStroke(); slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                slash.lineWidth = 1.7; (fill == nil ? NSColor.black : NSColor.white).setStroke(); slash.stroke()
            }
            return true
        }
        img.isTemplate = (fill == nil)
        img.accessibilityDescription = "MeetRec"
        return img
    }

    func micUID() -> String? { Config.shared.value["mic_id"] as? String }

    // Idle cost: the timer runs every 2 s when nothing happens (1 s with the mute on, so a mic
    // unmuted by another app is muted again quickly) and 4 times a second only while recording,
    // for the live bars. The icon is redrawn only when what it shows changes.
    var timerInterval: TimeInterval = 0
    var lastIconKey = ""
    var lastMuteTick = Date.distantPast

    func scheduleTimer() {
        let recording = current()?.alive == true
        let want: TimeInterval = recording ? 0.25 : (MicMute.shared.enabled || processing ? 1 : 2)
        guard want != timerInterval else { return }
        timer?.invalidate()
        timerInterval = want
        let t = Timer(timeInterval: want, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = want * 0.2            // let macOS batch wake-ups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard let b = item.button else { return }
        let cur = current()
        if Date().timeIntervalSince(lastMuteTick) >= 1 {
            lastMuteTick = Date()
            MicMute.shared.tick(micUID: micUID())
        }
        let muted = MicMute.shared.enabled
        var key: String, title: String
        var make: () -> NSImage
        if let c = cur {
            let db = LevelController.readLevels(c.dir)["mic"]?.0 ?? -120
            let bucket = Int(max(0, min(8, (db + 60) / 6)))      // 9 bar heights are enough for the eye
            key = c.alive ? "rec-\(bucket)-\(muted)" : "dead"
            make = { c.alive ? self.glyph(fill: .systemRed, level: db, muted: muted) : self.glyph(fill: .systemOrange, level: nil) }
            title = " " + elapsed(c.start)
        } else if processing {
            key = "proc"; title = " …"
            make = { self.glyph(fill: nil, level: nil) }
        } else {
            key = "idle-\(muted)"; title = ""
            make = { self.glyph(fill: nil, level: nil, muted: muted) }
        }
        if key != lastIconKey {
            b.image = make()
            b.imagePosition = .imageLeading
            lastIconKey = key
        }
        if b.title != title { b.title = title }
        scheduleTimer()
    }

    func loadRecover() {
        runMeet(["recover", "--json"]) { _, out in
            if let d = out.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { self.recover = arr }
        }
        runMeet(["list", "--json", "--n", "15"]) { _, out in
            if let line = out.split(separator: "\n").last,
               let arr = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]] { self.recent = arr }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cur = current()
        menu.addItem(levelItem)
        let mi = NSMenuItem(title: T("mute_mic_menu"), action: #selector(toggleMute), keyEquivalent: "m")
        mi.target = self
        mi.state = MicMute.shared.enabled ? .on : .off
        menu.addItem(mi)
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector?, key: String = "", enabled: Bool = true, fit: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: fit ? fitMenuTitle(title, room: key.isEmpty ? 286 : 230) : title, action: action, keyEquivalent: key)
            if i.title != title { i.toolTip = title }
            i.target = self; i.isEnabled = enabled && action != nil
            menu.addItem(i); return i
        }
        if let c = cur {
            // the timer always stays whole: only the meeting title is shortened
            let head = T("recording_for") + elapsed(c.start)
            let headW = (head as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
            let dashW = (" – " as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
            let t = c.title.map { " – " + fitMenuTitle($0, room: 286 - headW - dashW - 6) } ?? ""
            _ = add(c.alive ? head + t : T("the_recorder_stopped_stop_to_save"), nil, fit: !c.alive)   // keep the timer
            let sp = add(T("stop_and_process"), #selector(stopAndProcess), key: "r")
            sp.keyEquivalentModifierMask = [.command, .option, .control]
            _ = add(T("stop_without_processing"), #selector(stopOnly))
            _ = add(T("stop_and_discard"), #selector(stopAndDiscard))
        } else {
            if processing { _ = add(T("processing") + processingStep, nil) }
            let st = add(T("start_recording"), #selector(start), key: "r")
            st.keyEquivalentModifierMask = [.command, .option, .control]      // same as the global shortcut

            _ = add(T("start_with_title"), #selector(startWithTitle))
        }
        menu.addItem(.separator())
        if let n = lastNote {
            // shorten only the note name, after its date, so "Open last note: 2026-11-12 - …" stays readable
            let prefix = T("open_last_note"), name = (n as NSString).lastPathComponent
            let room = 286 - (prefix as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
            var short = name
            if (name as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width > room, name.count > 13 {
                let date = String(name.prefix(13))                                   // "2026-11-12 - "
                short = date + fitMenuTitle(String(name.dropFirst(13)), room: room - (date as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width)
            }
            let ln = add(prefix + short, #selector(openLastNote), fit: false)       // already shortened, keep the date
            ln.toolTip = name
        }
        _ = add(T("import_audio_file"), processing ? nil : #selector(importAudio), key: "i")
        _ = add(T("open_recordings_folder"), #selector(openRecordings))
        if !recent.isEmpty {
            // processed recordings: open the note, cut the audio afterwards, process again with instructions
            let sub = NSMenu()
            for r in recent {
                let when = (r["started_at"] as? String ?? "").prefix(16).replacingOccurrences(of: "T", with: " ")
                let item = NSMenuItem(title: fitMenuTitle("\(when) · \(r["title"] as? String ?? "")", room: 300), action: nil, keyEquivalent: "")
                let acts = NSMenu()
                let open = NSMenuItem(title: T("open_note"), action: (r["note_exists"] as? Bool ?? false) ? #selector(openNoteOf(_:)) : nil, keyEquivalent: "")
                open.target = self; open.representedObject = r["note"]
                let edit = NSMenuItem(title: T("edit_audio"), action: (r["has_audio"] as? Bool ?? false) && !processing ? #selector(editAfter(_:)) : nil, keyEquivalent: "")
                edit.target = self; edit.representedObject = r["dir"]
                let again = NSMenuItem(title: T("reprocess_with_instructions"), action: processing ? nil : #selector(reprocessWithInstructions(_:)), keyEquivalent: "")
                again.target = self; again.representedObject = r
                acts.addItem(open); acts.addItem(edit); acts.addItem(again)
                if !(r["has_audio"] as? Bool ?? false) {
                    let note = NSMenuItem(title: T("audio_deleted_short"), action: nil, keyEquivalent: "")
                    acts.addItem(note)
                }
                item.submenu = acts
                sub.addItem(item)
            }
            let m = add(T("recordings_menu"), nil)
            m.isEnabled = true; m.submenu = sub
        }
        if !recover.isEmpty {
            let sub = NSMenu()
            for r in recover {
                let title = "\(r["started_at"] as? String ?? "?") [\(r["duration"] as? String ?? "")] \(r["title"] as? String ?? "")"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let actions = NSMenu()
                let proc = NSMenuItem(title: T("process_now"), action: processing ? nil : #selector(processDir(_:)), keyEquivalent: "")
                proc.target = self; proc.representedObject = r["dir"]
                let del = NSMenuItem(title: T("delete_recording"), action: #selector(discardDir(_:)), keyEquivalent: "")
                del.target = self; del.representedObject = r["dir"]
                let ed = NSMenuItem(title: T("edit_audio"), action: processing ? nil : #selector(editDir(_:)), keyEquivalent: "")
                ed.target = self; ed.representedObject = r["dir"]
                actions.addItem(proc); actions.addItem(ed); actions.addItem(del)
                item.submenu = actions
                sub.addItem(item)
            }
            let m = add(T("to_process") + " (\(recover.count))", nil)
            m.isEnabled = true; m.submenu = sub
        }
        menu.addItem(.separator())
        _ = add(T("settings"), #selector(openSettings), key: ",")
        _ = add(T("setup_menu"), #selector(openSetup))
        _ = add("Log", #selector(openLog))
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        _ = add("MeetRec \(v)" + (b.isEmpty ? "" : " (\(b))"), nil)
        _ = add(T("quit_meetrec"), #selector(quit), key: "q")
        loadRecover()
    }

    // MARK: actions

    @objc func start() { startRecording(title: nil) }

    /// title + what to record, how to transcribe and the voice profile, for this recording only
    @objc func startWithTitle() {
        let cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any] ?? [:]
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        f.placeholderString = T("leave_empty_to_use_the_calendar_event")
        func popup(_ items: [(String, String)], _ current: String) -> NSPopUpButton {
            let b = NSPopUpButton()
            for (tag, key) in items { b.addItem(withTitle: T(key)); b.lastItem?.representedObject = tag }
            b.selectItem(at: items.firstIndex { $0.0 == current } ?? 0)
            return b
        }
        let rec = popup([("both", "record_both"), ("mine", "record_mine")],
                        (cfg["record_system"] as? Bool ?? true) ? "both" : "mine")
        let tr = popup([("separate", "transcript_separate"), ("mixed", "transcript_mixed")],
                       cfg["transcript_mode"] as? String ?? "separate")
        let vp = popup(voiceProfiles.map { ($0.0, $0.1) }, cfg["voice_profile"] as? String ?? "none")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: T("manual_title")), f],
            [NSTextField(labelWithString: T("what_to_record")), rec],
            [NSTextField(labelWithString: T("transcript_kind")), tr],
            [NSTextField(labelWithString: T("voice_profile")), vp],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 440, height: 130)
        let a = NSAlert()
        a.messageText = T("start_options_title")
        a.accessoryView = grid
        a.addButton(withTitle: T("record")); a.addButton(withTitle: T("cancel"))
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let t = f.stringValue.trimmingCharacters(in: .whitespaces)
        var extra = [(rec.selectedItem?.representedObject as? String) == "mine" ? "--mic-only" : "--with-system"]
        extra += ["--transcript", tr.selectedItem?.representedObject as? String ?? "separate"]
        extra += ["--voice-profile", vp.selectedItem?.representedObject as? String ?? "none"]
        startRecording(title: t.isEmpty ? nil : t, extra: extra)
    }

    // MARK: import an existing audio file (mp3, wav, m4a…): menu, Finder "Open With", drop on the app icon

    @objc func importAudio() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        p.message = T("import_panel_message")
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { importFile(u) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let u = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) ?? false }) {
            importFile(u)
        }
    }

    func importFile(_ url: URL) {
        guard !processing else {
            notify("MeetRec", T("import_busy"))
            return
        }
        let a = NSAlert()
        a.messageText = T("import_title", ["file": url.lastPathComponent])
        a.informativeText = T("import_title_info")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: T("import_button")); a.addButton(withTitle: T("cancel"))
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let t = f.stringValue.trimmingCharacters(in: .whitespaces)
        processing = true
        processingStep = T("import_copying")
        refresh()
        runMeet(["import", url.path, "--no-process"] + (t.isEmpty ? [] : ["-t", t])) { status, out in
            self.processing = false
            if status == 0, let d = LevelController.dirFrom(out, marker: "recording folder -> ") {
                self.chooseEventThenProcess(d)
            } else {
                notify(T("processing_failed"), out.split(separator: "\n").last.map(String.init) ?? "")
            }
        }
    }

    // MARK: call detection: offer "Record" when a call starts, "Stop" when it ends

    func callPromptEnabled() -> Bool { Config.shared.value["call_prompt"] as? Bool ?? true }

    func startCallWatcher() {
        calls.ownPIDs = {
            guard let d = FileManager.default.contents(atPath: stateFile),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = j["pid"] as? Int else { return [] }
            return [pid_t(pid)]
        }
        calls.onCallStart = { [weak self] app in
            guard let self else { return }
            let why = !self.callPromptEnabled() ? "prompt off in Settings" : self.current()?.alive == true ? "already recording"
                    : self.processing ? "processing a recording" : ""
            appendLog("[app] call detected: microphone used by \(app)" + (why.isEmpty ? ", prompt shown" : ", no prompt: \(why)") + "\n")
            guard why.isEmpty else { return }
            let show = { (event: String) in
                CallPrompt.shared.show(title: T("call_detected", ["app": app]),
                                       subtitle: event.isEmpty ? T("call_detected_sub") : event,
                                       primary: T("record"), secondary: T("ignore"),
                                       onPrimary: { self.startRecording(title: nil) })
            }
            show("")
            self.runMeet3(["now", "--json"]) { out in    // add the meeting title when a calendar has it
                let evs = out.split(separator: "\n").last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]] ?? []
                if let e = evs.first, let subj = e["subject"] as? String, self.current()?.alive != true, self.calls.inCall {
                    show(subj)
                }
            }
        }
        calls.onCallEnd = { [weak self] app in
            appendLog("[app] call ended: \(app) released the microphone\n")
            guard let self, self.callPromptEnabled(), self.current()?.alive == true else { return }
            CallPrompt.shared.show(title: T("call_ended", ["app": app]), subtitle: T("call_ended_sub"),
                                   primary: T("stop_and_process"), secondary: T("keep_recording"),
                                   onPrimary: { self.stopAndProcess() })
        }
        calls.start()
    }

    func runMeet3(_ args: [String], then: @escaping (String) -> Void) { runMeet(args) { _, out in then(out) } }

    func hotKeyPressed() {
        if current()?.alive == true {
            notify("MeetRec", T("hotkey_stopping"))
            stopAndProcess()
        } else if processing {
            notify("MeetRec", T("hotkey_busy"))
        } else {
            startRecording(title: nil)
            if current()?.alive == true || UserDefaults.standard.bool(forKey: "consentAcknowledged") {
                notify("MeetRec", T("hotkey_started"))
            }
        }
    }

    @objc func toggleMute() {
        MicMute.shared.enabled.toggle()
        MicMute.shared.tick(micUID: micUID())
        refresh()
    }

    func applicationWillTerminate(_ n: Notification) {
        setup.cancelLogin()                  // never leave a login waiting in the background
        MicMute.shared.restoreAll()          // never leave the mic muted without the app
    }

    /// once: recording a conversation without telling the others may be illegal where you are
    func consentAcknowledged() -> Bool {
        if UserDefaults.standard.bool(forKey: "consentAcknowledged") { return true }
        let a = NSAlert()
        a.messageText = T("consent_title")
        a.informativeText = T("consent_text")
        a.addButton(withTitle: T("consent_ok")); a.addButton(withTitle: T("cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: "consentAcknowledged")
        return true
    }

    func startRecording(title: String?, extra: [String] = []) {
        CallPrompt.shared.hide()
        guard consentAcknowledged() else { return }
        var args = ["start"]
        if let t = title { args += ["-t", t] }
        args += extra
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

    /// stop, then ask which calendar event it was (from every account), then process
    @objc func stopAndProcess() {
        runMeet(["stop", "--no-process"]) { _, out in
            self.refresh()
            if let d = LevelController.dirFrom(out, marker: "-> ") { self.chooseEventThenProcess(d) }
        }
    }

    func chooseEventThenProcess(_ dir: String) {
        processing = true
        processingStep = T("cal_looking")
        refresh()
        runMeet(["candidates", dir, "--json"]) { _, out in
            self.processing = false
            let cands = out.split(separator: "\n").last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]] ?? []
            let a = NSAlert()
            a.messageText = cands.isEmpty ? T("cal_no_event_found") : T("cal_which_meeting")
            a.informativeText = cands.isEmpty ? T("cal_no_event_info") : T("cal_which_meeting_info")
            let stack = NSStackView()
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
            var radios: [NSButton] = []
            let pick = { (b: NSButton) in radios.forEach { $0.state = $0 === b ? .on : .off } }
            for (i, c) in cands.enumerated() {
                let r = NSButton(radioButtonWithTitle: c["label"] as? String ?? "?", target: nil, action: nil)
                r.tag = i + 1
                radios.append(r)
            }
            let manual = NSButton(radioButtonWithTitle: T("cal_write_myself"), target: nil, action: nil)
            manual.tag = -1
            radios.append(manual)
            let none = NSButton(radioButtonWithTitle: cands.isEmpty ? T("cal_no_event") : T("cal_none_of_these"), target: nil, action: nil)
            none.tag = 0
            radios.append(none)
            for r in radios {
                r.target = RadioTarget.shared; r.action = #selector(RadioTarget.clicked(_:))
                stack.addArrangedSubview(r)
            }
            RadioTarget.shared.onClick = pick
            radios[0].state = .on
            // optional: instructions for Claude, and review/cut the audio before transcribing
            let instr = NSTextField(string: "")
            instr.placeholderString = T("instructions_placeholder")
            instr.widthAnchor.constraint(equalToConstant: 460).isActive = true
            let edit = NSButton(checkboxWithTitle: T("review_audio_first"), target: nil, action: nil)
            stack.setCustomSpacing(14, after: radios.last!)
            stack.addArrangedSubview(NSTextField(labelWithString: T("instructions_label")))
            stack.addArrangedSubview(instr)
            stack.addArrangedSubview(edit)
            stack.frame = NSRect(x: 0, y: 0, width: 460, height: CGFloat(radios.count) * 24 + 90)
            a.accessoryView = stack
            a.addButton(withTitle: T("cal_use_this")); a.addButton(withTitle: T("cal_decide_later"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else {
                notify("MeetRec", T("cal_saved_for_later"))
                self.loadRecover()
                return
            }
            let tag = radios.first { $0.state == .on }?.tag ?? 1
            let text = instr.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let review = edit.state == .on
            if tag == -1 {
                self.askManualEvent(dir, instructions: text, review: review)
                return
            }
            self.runMeet2(["choose", dir, tag == 0 ? "none" : "\(tag)"]) {
                self.continueToTranscript(dir, instructions: text, review: review)
            }
        }
    }

    /// form for a meeting that is not in any calendar: title, day, start, end, attendees, agenda
    /// after the meeting is chosen: optional audio editor, then processing with the instructions
    func continueToTranscript(_ dir: String, instructions: String, review: Bool) {
        let process = { self.runPipeline(["process", dir] + (instructions.isEmpty ? [] : ["--instructions", instructions])) }
        guard review else { process(); return }
        openEditor(dir) { applied in
            if applied { process() } else {
                notify("MeetRec", T("cal_saved_for_later"))
                self.loadRecover()
            }
        }
    }

    /// encode the raw audio, open the editor, apply the cuts; done(true) when there is something to transcribe
    func openEditor(_ dir: String, done: @escaping (Bool) -> Void) {
        processing = true
        processingStep = T("editor_preparing")
        refresh()
        runMeet(["prepare", dir]) { status, out in
            self.processing = false
            self.refresh()
            guard status == 0 else {
                notify(T("processing_failed"), out.split(separator: "\n").last.map(String.init) ?? "")
                done(false)
                return
            }
            AudioEditor.open(dir: dir) { cuts in
                guard let cuts else { done(false); return }
                guard !cuts.isEmpty else { done(true); return }
                let ranges = cuts.map { String(format: "%.2f-%.2f", $0.0, $0.1) }.joined(separator: ",")
                runMeet(["cut", dir, ranges]) { st, o in
                    if st != 0 { notify(T("processing_failed"), o.split(separator: "\n").last.map(String.init) ?? "") }
                    done(st == 0)
                }
            }
        }
    }

    @objc func openNoteOf(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? String { openObsidian(n) }
    }

    /// a processed recording: cut parts in the editor; transcript and note follow (no new transcription)
    @objc func editAfter(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? String else { return }
        AudioEditor.open(dir: d) { cuts in
            guard let cuts, !cuts.isEmpty else { return }
            let ranges = cuts.map { String(format: "%.2f-%.2f", $0.0, $0.1) }.joined(separator: ",")
            self.runPipeline(["edit", d, ranges])
        }
    }

    @objc func reprocessWithInstructions(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? [String: Any], let d = r["dir"] as? String else { return }
        let a = NSAlert()
        a.messageText = T("reprocess_title")
        a.informativeText = T("reprocess_info")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        f.stringValue = r["instructions"] as? String ?? ""
        f.placeholderString = T("instructions_placeholder")
        a.accessoryView = f
        a.addButton(withTitle: T("reprocess_button")); a.addButton(withTitle: T("cancel"))
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        runPipeline(["process", d] + (text.isEmpty ? [] : ["--instructions", text]))
    }

    @objc func editDir(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? String else { return }
        openEditor(d) { applied in if applied { self.chooseEventThenProcess(d) } else { self.loadRecover() } }
    }

    func askManualEvent(_ dir: String, instructions: String = "", review: Bool = false) {
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/meta.json")))) as? [String: Any] ?? [:]
        let isoIn = ISO8601DateFormatter()
        let start = (meta["started_at"] as? String).flatMap { isoIn.date(from: $0) } ?? Date()
        let end = (meta["stopped_at"] as? String).flatMap { isoIn.date(from: $0) } ?? start.addingTimeInterval(1800)

        let title = NSTextField(string: meta["title"] as? String ?? "")
        title.placeholderString = T("manual_title_placeholder")
        let day = NSDatePicker(); day.datePickerElements = [.yearMonthDay]; day.dateValue = start
        day.datePickerStyle = .textFieldAndStepper
        let t1 = NSDatePicker(); t1.datePickerElements = [.hourMinute]; t1.dateValue = start
        t1.datePickerStyle = .textFieldAndStepper
        let t2 = NSDatePicker(); t2.datePickerElements = [.hourMinute]; t2.dateValue = end
        t2.datePickerStyle = .textFieldAndStepper
        let people = NSTextField(string: "")
        people.placeholderString = T("manual_people_placeholder")
        let agenda = NSTextField(string: "")
        agenda.placeholderString = T("manual_agenda_placeholder")
        for f in [title, people, agenda] { f.widthAnchor.constraint(equalToConstant: 330).isActive = true }

        let times = NSStackView(views: [t1, NSTextField(labelWithString: "–"), t2])
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: T("manual_title")), title],
            [NSTextField(labelWithString: T("manual_day")), day],
            [NSTextField(labelWithString: T("manual_time")), times],
            [NSTextField(labelWithString: T("manual_people")), people],
            [NSTextField(labelWithString: T("manual_agenda")), agenda],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 440, height: 170)

        let a = NSAlert()
        a.messageText = T("manual_header")
        a.informativeText = T("manual_info")
        a.accessoryView = grid
        a.addButton(withTitle: T("manual_save")); a.addButton(withTitle: T("cal_decide_later"))
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = title
        while true {
            guard a.runModal() == .alertFirstButtonReturn else {
                notify("MeetRec", T("cal_saved_for_later"))
                loadRecover()
                return
            }
            if !title.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { break }
            NSSound.beep()                       // the title is required
        }
        // day from the day picker, hour and minute from the time pickers
        let cal = Calendar.current
        func combine(_ d: Date, _ t: Date) -> Date {
            var c = cal.dateComponents([.year, .month, .day], from: d)
            let tc = cal.dateComponents([.hour, .minute], from: t)
            c.hour = tc.hour; c.minute = tc.minute
            return cal.date(from: c) ?? d
        }
        let s1 = combine(day.dateValue, t1.dateValue)
        var s2 = combine(day.dateValue, t2.dateValue)
        if s2 <= s1 { s2 = s1.addingTimeInterval(1800) }
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone.current
        iso.formatOptions = [.withInternetDateTime]
        var args = ["choose", dir, "manual", "--title", title.stringValue.trimmingCharacters(in: .whitespaces),
                    "--start", iso.string(from: s1), "--end", iso.string(from: s2)]
        if !people.stringValue.isEmpty { args += ["--people", people.stringValue] }
        if !agenda.stringValue.isEmpty { args += ["--agenda", agenda.stringValue] }
        runMeet2(args) { self.continueToTranscript(dir, instructions: instructions, review: review) }
    }

    func runMeet2(_ args: [String], then: @escaping () -> Void) { runMeet(args) { _, _ in then() } }
    /// confirm, then delete: there is no undo
    func confirmDiscard(_ what: String) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = T("discard_confirm_title")
        a.informativeText = T("discard_confirm_info", ["what": what])
        let del = a.addButton(withTitle: T("delete_button"))
        del.hasDestructiveAction = true
        a.addButton(withTitle: T("cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc func stopAndDiscard() {
        guard let c = current(), confirmDiscard(T("discard_current", ["time": elapsed(c.start)])) else { return }
        runMeet(["stop", "--discard"]) { status, out in
            self.refresh()
            self.loadRecover()
            notify("MeetRec", status == 0 ? T("recording_discarded") : (out.split(separator: "\n").last.map(String.init) ?? ""))
        }
    }

    @objc func discardDir(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? String,
              confirmDiscard((d as NSString).lastPathComponent) else { return }
        runMeet(["discard", d]) { status, out in
            self.loadRecover()
            notify("MeetRec", status == 0 ? T("recording_discarded") : (out.split(separator: "\n").last.map(String.init) ?? ""))
        }
    }

    @objc func stopOnly() { runMeet(["stop", "--no-process"]) { _, _ in self.refresh(); self.loadRecover() } }
    @objc func processDir(_ sender: NSMenuItem) {
        if let d = sender.representedObject as? String { chooseEventThenProcess(d) }
    }

    /// "keep the audio?" after a transcript: asked only when meet verify confirms note + transcript
    func afterProcess(_ dir: String) {
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/meta.json")))) as? [String: Any] ?? [:]
        if meta["audio_deleted_at"] != nil { return }        // already deleted by the "delete" setting
        let cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any] ?? [:]
        guard (cfg["after_process_audio"] as? String ?? "ask") == "ask" else { return }
        runMeet(["verify", dir]) { status, out in
            let why = out.split(separator: "\n").last.map(String.init) ?? ""
            guard status == 0 else {
                notify(T("audio_kept_title"), why.replacingOccurrences(of: "NOT OK: ", with: ""))
                return
            }
            let a = NSAlert()
            a.messageText = T("keep_audio_title")
            a.informativeText = T("keep_audio_info", ["check": why.replacingOccurrences(of: "OK: ", with: "")])
            a.addButton(withTitle: T("keep_audio"))
            let del = a.addButton(withTitle: T("delete_audio"))
            del.hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertSecondButtonReturn {
                runMeet(["drop-audio", dir]) { st, out in
                    notify("MeetRec", st == 0 ? T("audio_deleted_done") : (out.split(separator: "\n").last.map(String.init) ?? ""))
                }
            }
        }
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
                if args.first == "process", args.count > 1 { self.afterProcess(args[1]) }
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
        setup.refresh()
        if setupWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(m: setup) { [weak self] in
                self?.setupWindow?.close()
            }))
            w.title = "MeetRec – Setup"
            w.delegate = self
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

/// a view on a dark rounded background (offscreen views have no window behind them)
func onDark(_ v: NSView, _ size: NSSize, radius: CGFloat = 12) -> NSView {
    let box = FlippedView(frame: NSRect(origin: .zero, size: size))
    box.appearance = NSAppearance(named: .darkAqua)
    box.wantsLayer = true
    box.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    box.layer?.cornerRadius = radius
    v.appearance = NSAppearance(named: .darkAqua)
    v.frame = NSRect(origin: .zero, size: size)
    box.addSubview(v)
    let w = NSWindow(contentRect: box.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: .darkAqua)
    w.contentView = box
    box.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    return box
}

/// an NSAlert drawn offscreen, as it looks on screen
func saveAlert(_ a: NSAlert, _ path: String) {
    a.window.appearance = NSAppearance(named: .darkAqua)
    a.layout()
    guard let cv = a.window.contentView else { return }
    cv.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let box = FlippedView(frame: cv.bounds)
    box.wantsLayer = true
    box.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
    box.layer?.cornerRadius = 14
    let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds)!
    cv.cacheDisplay(in: cv.bounds, to: rep)
    let img = NSImage(size: cv.bounds.size); img.addRepresentation(rep)
    let iv = NSImageView(frame: cv.bounds); iv.image = img
    box.addSubview(iv)
    savePNG(box, path)
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
    lv.setMuted(false, unsupported: false)
    let panel = NSView(frame: lv.frame)
    panel.appearance = dark
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    panel.layer?.cornerRadius = 10
    panel.addSubview(lv)
    savePNG(panel, dir + "/levels.png")

    // the menu, built by the app itself (same items, shortcuts and disabled rows as on screen),
    // drawn under the level panel: idle and while recording
    d.lastNote = ProcessInfo.processInfo.environment["MEETREC_DOCS_LASTNOTE"] ?? "/Users/you/Obsidian/Notes/Work/Meetings/2026-11/2026-11-09 - Weekly product sync.md"
    d.recover = [["started_at": "2026-11-06T15:02:11+01:00", "duration": "0h23m10s", "title": "Supplier call",
                  "dir": "/Users/you/Recordings/meetings/2026-11-06_150211"]]
    d.recent = [["started_at": "2026-11-09T10:00:12+01:00", "title": "Weekly product sync", "note": "/x.md", "note_exists": true,
                 "has_audio": true, "dir": "/Users/you/Recordings/meetings/2026-11-09_100012", "instructions": ""]]
    func drawMenu(_ file: String, recording: Bool) {
        d.docsRecording = recording ? Date().addingTimeInterval(-(12 * 60 + 34)) : nil
        let menu = NSMenu()
        d.menuNeedsUpdate(menu)
        let items = menu.items.filter { $0.view == nil }          // the level panel is drawn below
        let rowH: CGFloat = 24, sepH: CGFloat = 11, pad: CGFloat = 6
        let lv2 = LevelView()
        lv2.micName = lv.micName
        // idle: no live levels (they start only while recording), the Test mic button instead
        lv2.history = recording ? lv.history : []
        lv2.mic = recording ? lv.mic : (-120, -120)
        lv2.note = recording ? "" : T("preview_hint")
        lv2.testButton.title = T("test_mic")
        lv2.testButton.isHidden = recording
        lv2.sys = recording ? lv.sys : nil
        lv2.recording = recording
        lv2.setVolume(0.62); lv2.agcBox.state = .on; lv2.agcBox.title = lv.agcBox.title
        lv2.setMuted(false, unsupported: false)
        let itemsH = items.reduce(CGFloat(0)) { $0 + ($1.isSeparatorItem ? sepH : rowH) }
        // like macOS: the menu is as wide as its longest item plus the shortcut column; the panel follows
        let font0 = NSFont.menuFont(ofSize: 13)
        let widest = items.map { ($0.title as NSString).size(withAttributes: [.font: font0]).width + ($0.keyEquivalent.isEmpty && $0.submenu == nil ? 32 : 110) }.max() ?? 0
        let forced = Double(ProcessInfo.processInfo.environment["MEETREC_DOCS_MENUWIDTH"] ?? "") ?? 0
        lv2.setFrameSize(NSSize(width: max(lv2.frame.width, widest, CGFloat(forced)), height: lv2.frame.height))
        let menuView = FlippedView(frame: NSRect(x: 0, y: 0, width: lv2.frame.width, height: lv2.frame.height + itemsH + pad * 2))
        menuView.appearance = dark
        menuView.wantsLayer = true
        menuView.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        menuView.layer?.cornerRadius = 10
        lv2.frame.origin = NSPoint(x: 0, y: pad)
        menuView.addSubview(lv2)
        var y = lv2.frame.maxY
        let font = NSFont.menuFont(ofSize: 13)
        for it in items {
            if it.isSeparatorItem {
                let sep = NSBox(frame: NSRect(x: 14, y: y + sepH / 2, width: menuView.frame.width - 28, height: 1))
                sep.boxType = .separator
                menuView.addSubview(sep)
                y += sepH
                continue
            }
            let enabled = it.action != nil && it.isEnabled || it.submenu != nil
            var key = ""
            if it.submenu != nil { key = "›" } else if !it.keyEquivalent.isEmpty {
                let m = it.keyEquivalentModifierMask
                key = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "")
                    + (m.contains(.command) ? "⌘" : "") + it.keyEquivalent.uppercased()
            }
            let t = NSTextField(labelWithString: (it.state == .on ? "✓ " : "") + it.title)
            t.font = font; t.textColor = enabled ? .labelColor : .tertiaryLabelColor
            t.lineBreakMode = .byTruncatingTail
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
        savePNG(menuView, dir + "/" + file)
    }
    drawMenu("menu.png", recording: false)
    drawMenu("menu-recording.png", recording: true)
    d.docsRecording = nil

    // settings window (demo config from MEETREC_CONFIG_FILE, demo account)
    let st = Settings()
    st.load()
    st.account = "you@company.com"
    st.mics = [("MacBook Pro Microphone", "BuiltInMicrophoneDevice")]
    let host = NSHostingView(rootView: SettingsView(s: st))
    host.frame = NSRect(x: 0, y: 0, width: 560, height: 1240)
    host.appearance = dark
    let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    win.appearance = dark
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // let SwiftUI lay out
    st.account = "you@company.com"                           // whoami may have answered meanwhile
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    savePNG(host, dir + "/settings.png")

    // setup window (demo checks and accounts)
    let sm = SetupModel()
    sm.checks = [
        Check(id: "brew", title: "Homebrew", detail: "/opt/homebrew/bin/brew", ok: true, required: true, action: nil),
        Check(id: "python", title: "Python 3", detail: "/opt/homebrew/bin/python3", ok: true, required: true, action: nil),
        Check(id: "ffmpeg", title: "ffmpeg", detail: "/opt/homebrew/bin/ffmpeg", ok: true, required: true, action: nil),
        Check(id: "whisper", title: "whisper.cpp", detail: "/opt/homebrew/bin/whisper-cli", ok: true, required: true, action: nil),
        Check(id: "model", title: T("setup_model"), detail: "/Users/you/Library/Application Support/MeetRec/models/ggml-large-v3-turbo.bin",
              ok: true, required: true, action: nil),
        Check(id: "mic", title: T("setup_mic_permission"), detail: "OK", ok: true, required: true, action: nil),
        Check(id: "screen", title: T("setup_screen_permission"), detail: T("setup_screen_permission_detail"),
              ok: false, required: true, action: T("setup_allow")),
        Check(id: "vault", title: T("setup_vault"), detail: "/Users/you/Obsidian/Notes", ok: true, required: true, action: T("setup_choose")),
        Check(id: "calendars", title: T("cal_title"), detail: T("cal_count", ["n": "2"]), ok: true, required: false, action: nil),
        Check(id: "claude", title: T("setup_claude"), detail: "/Users/you/.local/bin/claude", ok: true, required: false, action: nil),
        Check(id: "cli", title: T("setup_cli"), detail: T("setup_cli_detail"), ok: false, required: false, action: T("setup_install")),
    ]
    sm.accounts = [CalAccount(id: "microsoft-1", provider: "microsoft", label: "you@company.com", ok: true),
                   CalAccount(id: "google-1", provider: "google", label: "you@gmail.com", ok: true)]
    sm.msClient = true; sm.googleClient = true
    let setupHost = NSHostingView(rootView: SetupView(m: sm) {})
    savePNG(onDark(setupHost, NSSize(width: 660, height: 860)), dir + "/setup.png")

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

    // ---- tour: the prompts and dialogs of a meeting, with demo data
    let prompt = NSHostingView(rootView: CallPromptView(
        title: T("call_detected", ["app": "Microsoft Teams"]), subtitle: "Weekly product sync",
        primary: T("record"), secondary: T("ignore"), onPrimary: {}, onSecondary: {}))
    savePNG(onDark(prompt, NSSize(width: 380, height: 120), radius: 16), dir + "/tour-call.png")

    // "which meeting was it?" with three events from two calendars
    let which = NSAlert()
    which.messageText = T("cal_which_meeting")
    which.informativeText = T("cal_which_meeting_info")
    let stack = NSStackView()
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
    let labels = ["10:00-10:45  Weekly product sync  [you@company.com]",
                  "10:30-11:00  Supplier call  [you@gmail.com]",
                  "10:00-11:00  Focus time  [macOS · iCloud]",
                  T("cal_write_myself"), T("cal_none_of_these")]
    for (i, l) in labels.enumerated() {
        let r = NSButton(radioButtonWithTitle: l, target: nil, action: nil)
        r.state = i == 0 ? .on : .off
        stack.addArrangedSubview(r)
    }
    let instr = NSTextField(string: "")
    instr.placeholderString = T("instructions_placeholder")
    instr.widthAnchor.constraint(equalToConstant: 460).isActive = true
    stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
    stack.addArrangedSubview(NSTextField(labelWithString: T("instructions_label")))
    stack.addArrangedSubview(instr)
    stack.addArrangedSubview(NSButton(checkboxWithTitle: T("review_audio_first"), target: nil, action: nil))
    stack.frame = NSRect(x: 0, y: 0, width: 460, height: CGFloat(labels.count) * 24 + 90)
    which.accessoryView = stack
    which.addButton(withTitle: T("cal_use_this")); which.addButton(withTitle: T("cal_decide_later"))
    saveAlert(which, dir + "/tour-which-meeting.png")

    // manual meeting details
    let form = NSAlert()
    form.messageText = T("manual_header")
    form.informativeText = T("manual_info")
    let title = NSTextField(string: "Call with supplier")
    let day = NSDatePicker(); day.datePickerElements = [.yearMonthDay]; day.datePickerStyle = .textFieldAndStepper
    let t1 = NSDatePicker(); t1.datePickerElements = [.hourMinute]; t1.datePickerStyle = .textFieldAndStepper
    let t2 = NSDatePicker(); t2.datePickerElements = [.hourMinute]; t2.datePickerStyle = .textFieldAndStepper
    var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 9; c.hour = 15; c.minute = 0
    let start = Calendar.current.date(from: c) ?? Date()
    day.dateValue = start; t1.dateValue = start; t2.dateValue = start.addingTimeInterval(45 * 60)
    let people = NSTextField(string: "Jane Doe, mark@supplier.com")
    let agenda = NSTextField(string: "Contract renewal and SLA")
    for f in [title, people, agenda] { f.widthAnchor.constraint(equalToConstant: 330).isActive = true }
    let grid = NSGridView(views: [
        [NSTextField(labelWithString: T("manual_title")), title],
        [NSTextField(labelWithString: T("manual_day")), day],
        [NSTextField(labelWithString: T("manual_time")), NSStackView(views: [t1, NSTextField(labelWithString: "–"), t2])],
        [NSTextField(labelWithString: T("manual_people")), people],
        [NSTextField(labelWithString: T("manual_agenda")), agenda],
    ])
    grid.rowSpacing = 8
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 440, height: 170)
    form.accessoryView = grid
    form.addButton(withTitle: T("manual_save")); form.addButton(withTitle: T("cal_decide_later"))
    saveAlert(form, dir + "/tour-manual.png")

    // keep or delete the audio
    let keep = NSAlert()
    keep.messageText = T("keep_audio_title")
    keep.informativeText = T("keep_audio_info", ["check": "42 transcript lines in 2026-11-09 - Weekly product sync.md"])
    keep.addButton(withTitle: T("keep_audio"))
    keep.addButton(withTitle: T("delete_audio")).hasDestructiveAction = true
    saveAlert(keep, dir + "/tour-keep-audio.png")
    AudioEditor.renderDemo(dir + "/tour-editor.png")

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
