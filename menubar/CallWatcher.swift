// Notices when a call starts (another app opens the microphone) and when it ends, so MeetRec
// can offer "Record" / "Stop" without looking for the menu. Core Audio per-process input state
// (macOS 14+): no permission needed, nothing is recorded.

import AppKit
import CoreAudio
import SwiftUI

final class CallWatcher {
    var onCallStart: ((String) -> Void)?
    var onCallEnd: ((String) -> Void)?
    /// processes that are ours (the recorder): not a call
    var ownPIDs: () -> Set<pid_t> = { [] }

    private var activeSince: Date?
    private var inactiveSince: Date?
    private(set) var inCall = false
    private(set) var callApp = ""
    private var timer: Timer?

    // dictation, Siri and system speech services open the mic too: not calls
    private let ignoredBundles = ["com.apple.siri", "com.apple.assistant", "com.apple.SpeechRecognitionCore",
                                  "com.apple.corespeech", "com.apple.dictation", "com.apple.accessibility"]

    func start() {
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 1                      // a call is noticed within a few seconds; let macOS batch wake-ups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// apps (by name) that are capturing from a microphone right now
    func micUsers() -> [String] {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        let mine = ownPIDs().union([ProcessInfo.processInfo.processIdentifier])
        var names: [String] = []
        for id in ids {
            var r = addr(kAudioProcessPropertyIsRunningInput)
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &r, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            var p = addr(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            s = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(id, &p, 0, nil, &s, &pid)
            if mine.contains(pid) { continue }
            var b = addr(kAudioProcessPropertyBundleID)
            var cf: Unmanaged<CFString>?
            s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(id, &b, 0, nil, &s, &cf)
            let bundle = (cf?.takeRetainedValue() as String?) ?? ""
            if ignoredBundles.contains(where: { bundle.lowercased().hasPrefix($0.lowercased()) }) { continue }
            names.append(appName(pid: pid, bundle: bundle))
        }
        return names
    }

    /// "Microsoft Teams", "Google Chrome"… (browser and Electron helpers map to their main app)
    private func appName(pid: pid_t, bundle: String) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if let r = path.range(of: ".app/") {     // outermost bundle: Chrome.app/…/Helper.app -> Chrome
                return URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app").deletingPathExtension().lastPathComponent
            }
            if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
            return URL(fileURLWithPath: path).lastPathComponent      // command line programs
        }
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        return bundle.isEmpty ? "pid \(pid)" : bundle
    }

    private func tick() {
        let users = micUsers()
        let now = Date()
        if let app = users.first {
            inactiveSince = nil
            if activeSince == nil { activeSince = now }
            if !inCall, now.timeIntervalSince(activeSince!) >= 3 {
                inCall = true
                callApp = app
                onCallStart?(app)
            }
        } else {
            activeSince = nil
            if inCall {
                if inactiveSince == nil { inactiveSince = now }
                if now.timeIntervalSince(inactiveSince!) >= 8 {
                    inCall = false
                    onCallEnd?(callApp)
                }
            }
        }
    }
}

// MARK: - the small prompt in the top right corner

struct CallPromptView: View {
    let title: String
    let subtitle: String
    let primary: String
    let secondary: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).lineLimit(2)
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                HStack {
                    Button(primary, action: onPrimary).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    Button(secondary, action: onSecondary)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

final class CallPrompt {
    static let shared = CallPrompt()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, subtitle: String, primary: String, secondary: String,
              onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void = {}) {
        hide()
        let view = CallPromptView(title: title, subtitle: subtitle, primary: primary, secondary: secondary,
                                  onPrimary: { [weak self] in self?.hide(); onPrimary() },
                                  onSecondary: { [weak self] in self?.hide(); onSecondary() })
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 12))
        }
        p.orderFrontRegardless()
        panel = p
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}
