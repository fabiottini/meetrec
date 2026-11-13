// Live audio levels in the MeetRec menu: mic + system meters, mic waveform, input volume, auto gain.
// While recording it reads <recording>/levels (written by meetrec-capture every 100 ms);
// otherwise it listens to the mic itself (AVAudioEngine) while the menu is open.

import AppKit
import AVFoundation
import CoreAudio

/// Preview of the mic when not recording.
final class MicPreview {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var peak: Float = 0, sumSq: Float = 0, n = 0, clipped = 0

    func start(uid: String?) -> Bool {
        let e = AVAudioEngine()
        let input = e.inputNode
        if let uid, !uid.isEmpty, var dev = MicVolume.deviceID(uid: uid), let au = input.audioUnit {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            var p: Float = 0, s: Float = 0, c = 0
            for i in 0..<Int(buf.frameLength) {
                let v = abs(ch[i]); if v > p { p = v }; if v >= 0.98 { c += 1 }; s += v * v
            }
            self.lock.lock()
            self.peak = max(self.peak, p); self.sumSq += s; self.n += Int(buf.frameLength); self.clipped += c
            self.lock.unlock()
        }
        do { try e.start() } catch { input.removeTap(onBus: 0); return false }
        engine = e
        return true
    }

    /// (rms dB, peak dB, clipped samples) since the last call
    func take() -> (Double, Double, Int) {
        lock.lock(); defer { peak = 0; sumSq = 0; n = 0; clipped = 0; lock.unlock() }
        guard n > 0 else { return (-120, -120, 0) }
        let rms = Double((sumSq / Float(n)).squareRoot()), pk = Double(peak)
        return (rms > 0 ? 20 * log10(rms) : -120, pk > 0 ? 20 * log10(pk) : -120, clipped)
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

final class LevelView: NSView {
    // data
    var mic = (rms: -120.0, peak: -120.0)
    var sys: (rms: Double, peak: Double)? = nil
    var history: [Double] = []
    var lastClip = Date.distantPast
    var micName = ""
    var note = ""

    let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    let volLabel = NSTextField(labelWithString: "")
    let agcBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let testButton = NSButton(title: "", target: nil, action: nil)
    var onTest: (() -> Void)?
    let muteButton = NSButton(title: "", target: nil, action: nil)
    var muted = false
    var recording = false
    var muteUnsupported = false
    var onMute: (() -> Void)?
    var onVolume: ((Float) -> Void)?
    var onAutoGain: ((Bool) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 222))
        slider.frame = NSRect(x: 16, y: 164, width: 210, height: 20)
        slider.target = self; slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        volLabel.frame = NSRect(x: 232, y: 166, width: 90, height: 16)
        volLabel.font = .systemFont(ofSize: 11); volLabel.textColor = .secondaryLabelColor
        agcBox.frame = NSRect(x: 14, y: 192, width: 300, height: 20)
        agcBox.font = .systemFont(ofSize: 12)
        agcBox.target = self; agcBox.action = #selector(agcToggled)
        muteButton.frame = NSRect(x: 226, y: 6, width: 92, height: 24)
        muteButton.bezelStyle = .rounded
        muteButton.font = .systemFont(ofSize: 12)
        muteButton.imageHugsTitle = true
        muteButton.imagePosition = .imageLeading
        muteButton.target = self; muteButton.action = #selector(muteClicked)
        testButton.frame = NSRect(x: 210, y: 130, width: 108, height: 24)
        testButton.bezelStyle = .rounded
        testButton.font = .systemFont(ofSize: 11)
        testButton.target = self; testButton.action = #selector(testClicked)
        testButton.isHidden = true
        addSubview(slider); addSubview(volLabel); addSubview(agcBox); addSubview(muteButton); addSubview(testButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func sliderMoved() { onVolume?(Float(slider.doubleValue / 100)) }
    @objc func agcToggled() { onAutoGain?(agcBox.state == .on) }
    @objc func muteClicked() { onMute?() }
    @objc func testClicked() { onTest?() }

    func setMuted(_ m: Bool, unsupported: Bool) {
        muted = m; muteUnsupported = unsupported
        muteButton.title = m ? T("unmute") : T("mute")
        muteButton.image = NSImage(systemSymbolName: m ? "mic.slash.fill" : "mic.fill", accessibilityDescription: nil)
        muteButton.contentTintColor = m ? .systemRed : nil
        needsDisplay = true
    }

    func push(mic m: (Double, Double), sys s: (Double, Double)?) {
        mic = (m.0, m.1); sys = s.map { ($0.0, $0.1) }
        history.append(m.0)
        if history.count > 90 { history.removeFirst(history.count - 90) }
        if m.1 > -1 { lastClip = Date() }
        needsDisplay = true
    }

    func setVolume(_ v: Float?) {
        if let v {
            slider.isEnabled = true
            if !(NSApp.currentEvent?.type == .leftMouseDragged) { slider.doubleValue = Double(v * 100) }
            volLabel.stringValue = "Volume \(Int((v * 100).rounded()))%"
        } else {
            slider.isEnabled = false
            volLabel.stringValue = T("not_adjustable")
        }
    }

    func status() -> (String, NSColor) {
        if muted {
            if muteUnsupported { return (T("mute_unsupported"), .systemOrange) }
            return (recording ? T("recording_while_muted") : T("mic_muted_status"), .systemRed)
        }
        if Date().timeIntervalSince(lastClip) < 2 { return (T("clipping_lower_the_volume"), .systemRed) }
        let loud = history.suffix(30).max() ?? -120
        if loud < -50 { return (T("silence_speak_to_test_the_level"), .secondaryLabelColor) }
        if loud < -32 { return (T("low_raise_the_mic_volume"), .systemOrange) }
        if loud > -8 { return (T("high_close_to_clipping"), .systemOrange) }
        return (T("level_ok"), .systemGreen)
    }

    static func frac(_ db: Double) -> CGFloat { CGFloat(max(0, min(1, (db + 60) / 60))) }

    func meter(_ label: String, _ v: (rms: Double, peak: Double)?, y: CGFloat) {
        let font = NSFont.systemFont(ofSize: 11)
        (label as NSString).draw(at: NSPoint(x: 16, y: y - 1), withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        let r = NSRect(x: 60, y: y, width: 254, height: 10)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        guard let v else {
            (T("only_while_recording") as NSString).draw(at: NSPoint(x: 66, y: y - 2),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor])
            return
        }
        // colour only the part up to the current level (the gradient keeps its full-scale position)
        let w = r.width * LevelView.frac(v.rms)
        if w > 0.5 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).addClip()
            NSRect(x: r.minX, y: r.minY, width: w, height: r.height).clip()
            NSGradient(colors: [.systemGreen, .systemGreen, .systemYellow, .systemRed],
                       atLocations: [0, 0.7, 0.86, 1], colorSpace: .sRGB)!.draw(in: r, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
        let px = r.minX + r.width * LevelView.frac(v.peak)
        (v.peak > -1 ? NSColor.systemRed : NSColor.labelColor).setFill()
        NSRect(x: px - 1, y: r.minY - 1, width: 2, height: r.height + 2).fill()
    }

    override func draw(_ dirty: NSRect) {
        let (txt, col) = status()
        // mic name: truncated so it never runs under the Mute button
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        (T("microphone_2") + micName as NSString).draw(in: NSRect(x: 16, y: 6, width: muteButton.frame.minX - 24, height: 16),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        (txt as NSString).draw(at: NSPoint(x: 16, y: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: col])

        // waveform of the mic, last ~9 s
        let wave = NSRect(x: 16, y: 42, width: 298, height: 40)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: wave, xRadius: 4, yRadius: 4).fill()
        let bw: CGFloat = 298 / 90
        for (i, db) in history.enumerated() {
            let h = max(1, wave.height * LevelView.frac(db))
            let x = wave.maxX - CGFloat(history.count - i) * bw
            let c: NSColor = db > -8 ? .systemRed : db < -50 ? .tertiaryLabelColor : db < -32 ? .systemOrange : .controlAccentColor
            c.setFill()
            NSRect(x: x, y: wave.midY - h / 2, width: max(1, bw - 1), height: h).fill()
        }

        meter(T("you"), mic, y: 92)
        meter(T("others"), sys, y: 110)
        if !note.isEmpty {
            // the note never runs under the Test mic button
            let np = NSMutableParagraphStyle(); np.lineBreakMode = .byTruncatingTail
            (note as NSString).draw(in: NSRect(x: 16, y: 135, width: (testButton.isHidden ? 298 : testButton.frame.minX - 24), height: 14),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: np])
        }
    }
}

/// Feeds the LevelView while the menu is open.
final class LevelController {
    let view = LevelView()
    private let preview = MicPreview()
    private var previewing = false
    private var isOpen = false
    // starting AVAudioEngine can take seconds (3 s with a Bluetooth headset): never on the main
    // thread, never automatically, or the menu freezes while it opens
    private let previewQueue = DispatchQueue(label: "meetrec.preview")
    private var timer: Timer?
    private var agc: AutoGain?
    var currentDir: () -> String? = { nil }
    var config: () -> [String: Any] = { [:] }
    var saveConfig: ([String: Any]) -> Void = { _ in }
    var onMute: (() -> Void)? {
        get { view.onMute }
        set { view.onMute = newValue }
    }

    init() {
        view.onVolume = { [weak self] v in
            guard let self, let d = MicVolume.deviceID(uid: self.micUID()) else { return }
            MicVolume.set(d, v)
            self.view.setVolume(MicVolume.get(d))
        }
        view.onTest = { [weak self] in self?.startPreview() }
        view.onAutoGain = { [weak self] on in
            guard let self else { return }
            var c = self.config(); c["auto_gain"] = on; self.saveConfig(c)
            self.agc?.enabled = on
        }
    }

    func micUID() -> String? { config()["mic_id"] as? String }

    func open() {
        let uid = micUID()
        let dev = MicVolume.deviceID(uid: uid)
        let autoOn = config()["auto_gain"] as? Bool ?? true
        view.micName = dev.map(MicVolume.name) ?? "?"
        view.agcBox.title = T("lower_automatically_when_clipping")
        view.agcBox.state = autoOn ? .on : .off
        view.setMuted(MicMute.shared.enabled, unsupported: MicMute.shared.unsupported)
        view.setVolume(dev.flatMap(MicVolume.get))
        view.history = []
        agc = AutoGain(uid: uid, enabled: autoOn)
        isOpen = true
        let idle = currentDir() == nil
        view.note = idle ? T("preview_hint") : ""
        view.testButton.title = T("test_mic")
        view.testButton.isHidden = !idle
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)       // keeps running while the menu is tracking
        timer = t
    }

    func startPreview() {
        let uid = micUID()
        view.testButton.isHidden = true
        view.note = T("preview_starting")
        let go = {
            self.previewQueue.async {
                let ok = self.preview.start(uid: uid)
                DispatchQueue.main.async {
                    guard self.isOpen else { self.previewQueue.async { self.preview.stop() }; return }
                    self.previewing = ok
                    self.view.note = ok ? T("preview_the_mic_is_listening_while_the") : T("mic_preview_not_available_permission")
                }
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: go()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { if ok { go() } } }
        default: view.note = T("microphone_permission_denied_to_meetrec_settings_privacy")
        }
    }

    func close() {
        isOpen = false
        timer?.invalidate(); timer = nil
        if previewing {
            previewing = false
            previewQueue.async { self.preview.stop() }
        }
    }

    private func tick() {
        let dev = MicVolume.deviceID(uid: micUID())
        if let dir = currentDir() {
            if previewing { previewing = false; previewQueue.async { self.preview.stop() }; view.note = "" }
            view.testButton.isHidden = true
            let l = LevelController.readLevels(dir)
            view.push(mic: l["mic"] ?? (-120, -120), sys: l["system"] ?? (-120, -120))
        } else if previewing {
            let m = preview.take()
            agc?.observe(clipped: m.2)
            view.push(mic: (m.0, m.1), sys: nil)
        }
        view.setVolume(dev.flatMap(MicVolume.get))
        view.recording = currentDir() != nil
        view.setMuted(MicMute.shared.enabled, unsupported: MicMute.shared.unsupported)
    }

    /// recording folder printed by meet ("… -> /path" or "recording folder -> /path")
    static func dirFrom(_ out: String, marker: String) -> String? {
        for line in out.split(separator: "\n").reversed() {
            if let r = line.range(of: marker) {
                let d = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if FileManager.default.fileExists(atPath: d) { return d }
            }
        }
        return nil
    }

    static func readLevels(_ dir: String) -> [String: (Double, Double)] {
        guard let s = try? String(contentsOfFile: dir + "/levels", encoding: .utf8) else { return [:] }
        var out: [String: (Double, Double)] = [:]
        for line in s.split(separator: "\n") {
            let p = line.split(separator: " ")
            if p.count == 3, let a = Double(p[1]), let b = Double(p[2]) { out[String(p[0])] = (a, b) }
        }
        return out
    }
}
