// First-run setup: checks everything MeetRec needs and installs what is missing.
// Opens by itself when something required is missing, and from the menu ("Setup…").

import AppKit
import AVFoundation
import CoreGraphics
import CryptoKit
import SwiftUI

let toolPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
let dataDir = URL(fileURLWithPath: "\(home)/Library/Application Support/MeetRec")
let vibeDir = "\(home)/Library/Application Support/github.com.thewh1teagle.vibe"
// SHA-256 from the Hugging Face file listings (LFS oid): a changed or damaged download is refused
let models: [(file: String, url: String, sha256: String)] = [
    ("ggml-large-v3-turbo.bin", "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
     "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
    ("ggml-silero-v6.2.0.bin", "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin",
     "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"),
]

/// SHA-256 of a file, read in 8 MB blocks (the model is 1.6 GB)
func sha256(of url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while let d = try? h.read(upToCount: 8 << 20), !d.isEmpty { hasher.update(data: d) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func findTool(_ name: String) -> String? {
    toolPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Python 3 for meet.py: Homebrew's, or Apple's when the Command Line Tools are installed
/// (/usr/bin/python3 alone is only a stub that asks to install them).
func findPython() -> String? {
    for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where FileManager.default.isExecutableFile(atPath: p) {
        return p
    }
    let clt = ["/Library/Developer/CommandLineTools/usr/bin/python3",
               "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
    return clt.contains { FileManager.default.fileExists(atPath: $0) } ? "/usr/bin/python3" : nil
}

func modelPath(_ file: String) -> String? {
    ["\(dataDir.path)/models/\(file)", "\(vibeDir)/\(file)"].first { FileManager.default.fileExists(atPath: $0) }
}

/// command line `meet` wrapper pointing to this app
let cliPath = "\(home)/.local/bin/meet"
func cliWrapper() -> String? {
    guard let py = findPython(), let res = Bundle.main.resourceURL?.path else { return nil }
    let capture = Bundle.main.bundlePath + "/Contents/MacOS/meetrec-capture"
    return "#!/bin/sh\n# installed by MeetRec.app\nMEETREC_CAPTURE=\"\(capture)\" exec \"\(py)\" \"\(res)/meet.py\" \"$@\"\n"
}

struct CalAccount: Identifiable {
    let id: String
    let provider: String
    let label: String
    let ok: Bool
}

struct Check: Identifiable {
    let id: String
    var title: String
    var detail: String
    var ok: Bool
    var required: Bool
    var action: String?       // button label, nil = nothing to do
}

final class SetupModel: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var checks: [Check] = []
    @Published var log = ""
    @Published var busy: String? = nil
    @Published var progress: Double? = nil
    @Published var accounts: [CalAccount] = []
    @Published var googleClient = false
    @Published var msClient = false
    @Published var ai: [String: Any] = [:]
    @Published var loginMessage = ""
    @Published var loginRunning = false
    @Published var loginURL = ""
    private var loginProc: Process?
    private var loginCancelled = false
    private var downloadQueue: [(file: String, url: String, sha256: String)] = []

    var requiredMissing: Bool { checks.contains { $0.required && !$0.ok } }

    func refresh(_ done: (() -> Void)? = nil) {
        runMeet(["ai", "--json"]) { _, out in
            self.ai = out.split(separator: "\n").last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
            self.build()
        }
        runMeet(["accounts", "--json"]) { _, out in
            let j = out.split(separator: "\n").last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            self.accounts = (j?["accounts"] as? [[String: Any]] ?? []).map {
                CalAccount(id: $0["id"] as? String ?? "", provider: $0["provider"] as? String ?? "",
                           label: $0["label"] as? String ?? "", ok: $0["ok"] as? Bool ?? false)
            }
            self.googleClient = j?["google_client"] as? Bool ?? false
            self.msClient = j?["ms_client"] as? Bool ?? false
            self.build()
            done?()
        }
        build()
    }

    // MARK: calendar accounts

    /// shared by Microsoft (device code: copy the code, open the page) and Google (browser opens by itself)
    func cancelLogin() {
        guard let p = loginProc, p.isRunning else { return }
        loginCancelled = true
        p.terminate()
    }

    private func runLogin(_ args: [String]) {
        busy = T("cal_logging_in")
        loginMessage = ""
        loginCancelled = false
        loginRunning = true
        loginURL = ""
        loginProc = runMeet(args, onLine: { line in
            if let urlR = line.range(of: #"https://microsoft\.com/\S+|https://login\.microsoft\S+"#, options: .regularExpression),
               let codeR = line.range(of: #"code ([A-Z0-9]+)"#, options: .regularExpression) {
                let code = String(line[codeR].dropFirst(5))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                self.loginMessage = T("login_code_copied", ["code": code])
                self.loginURL = String(line[urlR])
                if let u = URL(string: self.loginURL) { NSWorkspace.shared.open(u) }
            } else if let r = line.range(of: #"https://accounts\.google\.com/\S+"#, options: .regularExpression) {
                self.loginURL = String(line[r])
                self.loginMessage = T("cal_google_browser")
            }
        }) { status, out in
            self.busy = nil
            self.loginRunning = false
            self.loginProc = nil
            self.loginURL = ""
            if self.loginCancelled {
                self.loginMessage = T("cal_login_cancelled")
                self.refresh()
                return
            }
            self.loginMessage = status == 0 ? T("logged_in") : T("login_failed") + (out.split(separator: "\n").last.map(String.init) ?? "")
            self.log += out.split(separator: "\n").filter { $0.hasPrefix("[meet]") }.joined(separator: "\n") + "\n"
            self.refresh()
        }
    }

    func addMicrosoft() {
        if msClient { runLogin(["account", "add", "microsoft"]); return }
        MicrosoftGuide.shared.show { [weak self] cid in
            runMeet(["account", "ms-client", cid]) { status, out in
                self?.log += out
                if status == 0 {
                    MicrosoftGuide.shared.close()
                    self?.msClient = true
                    self?.runLogin(["account", "add", "microsoft"])
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    func addGoogle() {
        if googleClient { runLogin(["account", "add", "google"]); return }
        GoogleGuide.shared.show { [weak self] path in
            runMeet(["account", "google-client", path]) { status, out in
                self?.log += out
                if status == 0 {
                    GoogleGuide.shared.close()
                    self?.googleClient = true
                    self?.runLogin(["account", "add", "google"])
                }
            }
        }
    }

    func addMacOS() {
        busy = T("cal_macos_access")
        runMeet(["account", "add", "macos"]) { status, out in
            self.busy = nil
            self.log += out
            if status != 0 {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
            self.refresh()
        }
    }

    func remove(_ id: String) {
        runMeet(["account", "remove", id]) { _, out in self.log += out; self.refresh() }
    }

    private func build() {
        let brew = findTool("brew")
        let cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any] ?? [:]
        let vault = cfg["vault"] as? String ?? ""
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let screenOK = CGPreflightScreenCaptureAccess()
        let cliOK = (try? String(contentsOfFile: cliPath, encoding: .utf8)) == cliWrapper()
        let model = modelPath(models[0].file)
        checks = [
            Check(id: "brew", title: "Homebrew", detail: brew ?? T("setup_brew_missing"),
                  ok: brew != nil, required: true, action: brew == nil ? T("setup_how_to_install") : nil),
            Check(id: "python", title: "Python 3", detail: findPython() ?? T("setup_python_missing"),
                  ok: findPython() != nil, required: true, action: findPython() == nil ? T("setup_install") : nil),
            Check(id: "ffmpeg", title: "ffmpeg", detail: findTool("ffmpeg") ?? "brew install ffmpeg",
                  ok: findTool("ffmpeg") != nil, required: true, action: findTool("ffmpeg") == nil ? T("setup_install") : nil),
            Check(id: "whisper", title: "whisper.cpp", detail: findTool("whisper-cli") ?? "brew install whisper-cpp",
                  ok: findTool("whisper-cli") != nil, required: true, action: findTool("whisper-cli") == nil ? T("setup_install") : nil),
            Check(id: "model", title: T("setup_model"),
                  detail: model.map { $0.hasPrefix(vibeDir) ? T("setup_model_in_vibe") : $0 } ?? T("setup_model_missing"),
                  ok: model != nil && modelPath(models[1].file) != nil, required: true,
                  action: model == nil || modelPath(models[1].file) == nil ? T("setup_download")
                        : (models.contains { modelPath($0.file)!.hasPrefix(vibeDir) } ? T("setup_copy_from_vibe") : nil)),
            Check(id: "mic", title: T("setup_mic_permission"), detail: micOK ? "OK" : T("setup_mic_permission_detail"),
                  ok: micOK, required: true, action: micOK ? nil : T("setup_allow")),
            Check(id: "screen", title: T("setup_screen_permission"), detail: screenOK ? "OK" : T("setup_screen_permission_detail"),
                  ok: screenOK, required: true, action: screenOK ? nil : T("setup_allow")),
            Check(id: "vault", title: T("setup_vault"), detail: vault.isEmpty ? T("setup_vault_missing") : vault,
                  ok: !vault.isEmpty && FileManager.default.fileExists(atPath: vault), required: true, action: T("setup_choose")),
            Check(id: "calendars", title: T("cal_title"),
                  detail: accounts.isEmpty ? T("cal_none") : T("cal_count", ["n": "\(accounts.count)"]),
                  ok: !accounts.isEmpty && accounts.allSatisfy(\.ok), required: false, action: nil),
            aiCheck(),
            Check(id: "cli", title: T("setup_cli"), detail: cliOK ? cliPath : T("setup_cli_detail"),
                  ok: cliOK, required: false, action: cliOK ? nil : T("setup_install")),
        ]
    }

    /// the AI provider chosen in Settings: ready or why not (optional: without it notes have only the transcript)
    private func aiCheck() -> Check {
        let provider = ai["provider"] as? String ?? "claude-code"
        let model = ai["model"] as? String ?? ""
        let ready = ai["ready"] as? Bool ?? false
        let name = T(aiProviders.first { $0.0 == provider }?.1 ?? provider) + (model.isEmpty || provider == "command" ? "" : " · \(model)")
        return Check(id: "ai", title: T("setup_ai"), detail: ready ? name : name + ": " + (ai["why"] as? String ?? "…"),
                     ok: ready, required: false, action: nil)
    }

    func run(_ id: String) {
        switch id {
        case "brew":
            let cmd = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            log += T("setup_brew_copied") + "\n"
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
        case "python": brewInstall(["python"])
        case "ffmpeg": brewInstall(["ffmpeg"])
        case "whisper": brewInstall(["whisper-cpp"])
        case "model": installModels()
        case "mic":
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.build() } }
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        case "screen":
            if !CGRequestScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                log += T("setup_screen_restart") + "\n"
            }
            build()
        case "vault": chooseVault()
        case "cli": installCLI()
        default: break
        }
    }

    // MARK: actions

    private func brewInstall(_ pkgs: [String]) {
        guard let brew = findTool("brew") else { return }
        busy = "brew install " + pkgs.joined(separator: " ")
        log += "$ \(busy!)\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = ["install"] + pkgs
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPaths.joined(separator: ":") + ":/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"     // much faster; update separately if needed
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            if let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty {
                DispatchQueue.main.async { self.log += s }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.log += proc.terminationStatus == 0 ? "✓\n" : "✗ exit \(proc.terminationStatus)\n"
                self.busy = nil
                self.build()
            }
        }
        do { try p.run() } catch { log += "\(error)\n"; busy = nil }
    }

    private func installModels() {
        let dir = dataDir.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        downloadQueue = []
        for m in models where modelPath(m.file) == nil || modelPath(m.file)!.hasPrefix(vibeDir) {
            let dest = dir.appendingPathComponent(m.file)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            if FileManager.default.fileExists(atPath: "\(vibeDir)/\(m.file)") {
                // copy from Vibe (APFS clone: instant, no extra space) so Vibe can be removed later
                try? FileManager.default.copyItem(atPath: "\(vibeDir)/\(m.file)", toPath: dest.path)
                log += T("setup_model_copied", ["file": m.file]) + "\n"
            } else {
                downloadQueue.append(m)
            }
        }
        nextDownload()
        build()
    }

    private func nextDownload() {
        guard !downloadQueue.isEmpty else { busy = nil; progress = nil; build(); return }
        let m = downloadQueue[0]
        busy = T("setup_downloading", ["file": m.file])
        progress = 0
        log += "↓ \(m.url)\n"
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        s.downloadTask(with: URL(string: m.url)!).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        if t > 0 { progress = Double(w) / Double(t) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let m = downloadQueue.removeFirst()
        let dest = dataDir.appendingPathComponent("models/\(m.file)")
        let part = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        session.finishTasksAndInvalidate()
        do { try FileManager.default.moveItem(at: location, to: part) } catch {
            log += "✗ \(m.file): \(error.localizedDescription)\n"
            nextDownload()
            return
        }
        busy = T("setup_win_verifying", ["file": m.file])
        progress = nil
        DispatchQueue.global(qos: .utility).async {
            let got = sha256(of: part)
            DispatchQueue.main.async {
                if got == m.sha256 {
                    try? FileManager.default.removeItem(at: dest)
                    do { try FileManager.default.moveItem(at: part, to: dest); self.log += "✓ \(m.file) (SHA-256 ok)\n" }
                    catch { self.log += "✗ \(m.file): \(error.localizedDescription)\n" }
                    self.nextDownload()
                } else {
                    try? FileManager.default.removeItem(at: part)
                    self.log += "✗ \(m.file): SHA-256 \(got ?? "?") ≠ \(m.sha256)\n"
                    self.downloadQueue = []
                    self.nextDownload()
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            log += "✗ \(error.localizedDescription)\n"
            downloadQueue = []
            busy = nil; progress = nil
            build()
        }
    }

    private func chooseVault() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = T("setup_vault_panel")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        var cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any] ?? [:]
        cfg["vault"] = u.path
        try? FileManager.default.createDirectory(atPath: (configFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: configFile), options: .atomic)
        }
        build()
    }

    private func installCLI() {
        guard let w = cliWrapper() else { return }
        try? FileManager.default.createDirectory(atPath: "\(home)/.local/bin", withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: cliPath)
        do {
            try w.write(toFile: cliPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliPath)
            log += T("setup_cli_done", ["path": cliPath]) + "\n"
        } catch { log += "✗ \(error.localizedDescription)\n" }
        build()
    }
}

struct SetupView: View {
    @ObservedObject var m: SetupModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(T("setup_title")).font(.title2).bold()
                    Text(T("setup_subtitle")).foregroundStyle(.secondary)
                }
            }
            List(m.checks) { c in
                HStack(alignment: .top) {
                    Image(systemName: c.ok ? "checkmark.circle.fill" : (c.required ? "xmark.circle.fill" : "minus.circle"))
                        .foregroundStyle(c.ok ? .green : (c.required ? .red : .secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title + (c.required ? "" : "  · " + T("setup_optional")))
                        Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                    if let a = c.action {
                        Button(a) { m.run(c.id) }.disabled(m.busy != nil)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 330)
            GroupBox(T("cal_title")) {
                VStack(alignment: .leading, spacing: 6) {
                    if m.accounts.isEmpty { Text(T("cal_none_detail")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(m.accounts) { a in
                        HStack {
                            Image(systemName: a.provider == "google" ? "g.circle" : a.provider == "macos" ? "calendar" : "m.circle")
                            Text(a.label.isEmpty ? a.id : a.label)
                            if !a.ok { Text(T("cal_login_needed")).font(.caption).foregroundStyle(.orange) }
                            Spacer()
                            Button(T("cal_remove")) { m.remove(a.id) }.disabled(m.busy != nil)
                        }
                    }
                    HStack {
                        Button(T("cal_add_ms")) { m.addMicrosoft() }
                        Button(T("cal_add_google")) { m.addGoogle() }
                        if !m.accounts.contains(where: { $0.provider == "macos" }) {
                            Button(T("cal_add_macos")) { m.addMacOS() }
                        }
                    }
                    .disabled(m.busy != nil)
                    if !m.loginMessage.isEmpty || m.loginRunning {
                        HStack {
                            Text(m.loginMessage).font(.caption).textSelection(.enabled)
                            Spacer()
                            if m.loginRunning { Button(T("cancel")) { m.cancelLogin() } }
                        }
                        if m.loginRunning && !m.loginURL.isEmpty {
                            HStack {
                                Text(m.loginURL).font(.system(.caption, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Spacer()
                                Button(T("cal_copy_link")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(m.loginURL, forType: .string)
                                }
                            }
                            Text(T("cal_other_browser")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            if let b = m.busy {
                HStack {
                    if let p = m.progress { ProgressView(value: p).frame(width: 200) } else { ProgressView().controlSize(.small) }
                    Text(b + (m.progress.map { String(format: " %.0f%%", $0 * 100) } ?? "")).font(.caption)
                }
            }
            if !m.log.isEmpty {
                ScrollView {
                    Text(m.log).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 110)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button(T("setup_recheck")) { m.refresh() }.disabled(m.busy != nil)
                Spacer()
                Text(m.requiredMissing ? T("setup_missing") : T("setup_ready"))
                    .foregroundStyle(m.requiredMissing ? .orange : .green)
                Button(T("setup_close")) { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 660, height: 860)
    }
}


// MARK: - step by step guide for the Google OAuth client (once)

struct GoogleGuideView: View {
    let onJSON: (String) -> Void
    let onClose: () -> Void
    let steps: [(String, String, String?)] = [
        ("g1_title", "g1_text", "https://console.cloud.google.com/projectcreate"),
        ("g2_title", "g2_text", "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com"),
        ("g3_title", "g3_text", "https://console.cloud.google.com/apis/credentials/consent"),
        ("g4_title", "g4_text", "https://console.cloud.google.com/auth/audience"),
        ("g5_title", "g5_text", "https://console.cloud.google.com/apis/credentials"),
        ("g6_title", "g6_text", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T("g_title")).font(.title2).bold()
            Text(T("g_intro")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, st in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(.headline).frame(width: 24, height: 24)
                                .background(Circle().fill(Color.accentColor.opacity(0.25)))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(T(st.0)).font(.headline)
                                Text(T(st.1)).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if let u = st.2 {
                                Button(T("g_open")) { NSWorkspace.shared.open(URL(string: u)!) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button(T("cancel")) { onClose() }
                Spacer()
                Button(T("cal_google_choose_json")) {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.json]
                    p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    NSApp.activate(ignoringOtherApps: true)
                    if p.runModal() == .OK, let u = p.url { onJSON(u.path) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 680)
    }
}

final class GoogleGuide {
    static let shared = GoogleGuide()
    private var window: NSWindow?

    func show(onJSON: @escaping (String) -> Void) {
        let v = GoogleGuideView(onJSON: onJSON, onClose: { [weak self] in self?.close() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: v))
        w.title = "MeetRec – Google"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close(); window = nil }
}


// MARK: - step by step guide for your own Microsoft app registration (once)

/// text of the client id field (an ObservableObject: @State is a macro the Command Line Tools cannot expand)
final class ClientIDField: ObservableObject { @Published var value = "" }

struct MicrosoftGuideView: View {
    let onSave: (String) -> Void
    let onClose: () -> Void
    @ObservedObject var field: ClientIDField
    let steps: [(String, String, String?)] = [
        ("m1_title", "m1_text", "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"),
        ("m2_title", "m2_text", nil),
        ("m3_title", "m3_text", nil),
        ("m4_title", "m4_text", nil),
        ("m5_title", "m5_text", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T("m_title")).font(.title2).bold()
            Text(T("m_intro")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, st in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(.headline).frame(width: 24, height: 24)
                                .background(Circle().fill(Color.accentColor.opacity(0.25)))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(T(st.0)).font(.headline)
                                Text(T(st.1)).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if let u = st.2 {
                                Button(T("g_open")) { NSWorkspace.shared.open(URL(string: u)!) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                TextField("00000000-0000-0000-0000-000000000000", text: $field.value)
                    .font(.system(.body, design: .monospaced))
                Button(T("m_save")) { onSave(field.value.trimmingCharacters(in: .whitespaces)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(field.value.trimmingCharacters(in: .whitespaces).count < 36)
            }
            HStack {
                Button(T("cancel")) { onClose() }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
    }
}

final class MicrosoftGuide {
    static let shared = MicrosoftGuide()
    private var window: NSWindow?

    func show(onSave: @escaping (String) -> Void) {
        let v = MicrosoftGuideView(onSave: onSave, onClose: { [weak self] in self?.close() }, field: ClientIDField())
        let w = NSWindow(contentViewController: NSHostingController(rootView: v))
        w.title = "MeetRec – Microsoft"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close(); window = nil }
}
