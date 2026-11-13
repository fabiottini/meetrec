// Audio editor: look at the whole recording, select parts by dragging, listen to them, cut them,
// then transcribe. The cuts are applied by `meet cut` to every track (verified durations).

import AppKit
import AVFoundation

final class WaveformView: NSView {
    var peaks: [Double] = []
    var duration: Double = 1
    var selection: (Double, Double)? { didSet { needsDisplay = true; onSelection?() } }
    var cuts: [(Double, Double)] = [] { didSet { needsDisplay = true } }
    var playhead: Double? { didSet { needsDisplay = true } }
    var onSelection: (() -> Void)?
    private var dragStart: Double?

    override var isFlipped: Bool { true }

    func time(at x: CGFloat) -> Double { max(0, min(duration, Double(x / bounds.width) * duration)) }
    func x(at t: Double) -> CGFloat { CGFloat(t / max(duration, 0.001)) * bounds.width }

    override func mouseDown(with e: NSEvent) {
        let t = time(at: convert(e.locationInWindow, from: nil).x)
        dragStart = t
        selection = (t, t)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStart else { return }
        let t = time(at: convert(e.locationInWindow, from: nil).x)
        selection = (min(s, t), max(s, t))
        autoscroll(with: e)
    }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        // time grid: a line every minute (every 10 s when zoomed in enough)
        let step: Double = bounds.width / CGFloat(max(duration, 1)) > 6 ? 10 : 60
        var t = 0.0
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        while t <= duration {
            let gx = x(at: t)
            NSColor(white: 1, alpha: 0.08).setFill()
            NSRect(x: gx, y: 0, width: 1, height: bounds.height).fill()
            if Int(t) % Int(step * (step == 10 ? 3 : 5)) == 0 {
                (hmsShort(t) as NSString).draw(at: NSPoint(x: gx + 3, y: 2), withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            }
            t += step
        }
        // cuts
        for (a, b) in cuts {
            NSColor.systemRed.withAlphaComponent(0.35).setFill()
            NSRect(x: x(at: a), y: 0, width: max(1, x(at: b) - x(at: a)), height: bounds.height).fill()
        }
        // waveform
        let mid = bounds.height / 2 + 6
        let n = max(peaks.count, 1)
        let bw = bounds.width / CGFloat(n)
        NSColor.controlAccentColor.setFill()
        for (i, p) in peaks.enumerated() {
            let h = max(1, CGFloat(p) * (bounds.height - 24))
            NSRect(x: CGFloat(i) * bw, y: mid - h / 2, width: max(1, bw - 0.3), height: h).fill()
        }
        // selection
        if let (a, b) = selection, b - a > 0.05 {
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSRect(x: x(at: a), y: 0, width: x(at: b) - x(at: a), height: bounds.height).fill()
            NSColor.white.withAlphaComponent(0.7).setFill()
            NSRect(x: x(at: a), y: 0, width: 1, height: bounds.height).fill()
            NSRect(x: x(at: b), y: 0, width: 1, height: bounds.height).fill()
        }
        if let p = playhead {
            NSColor.systemYellow.setFill()
            NSRect(x: x(at: p) - 1, y: 0, width: 2, height: bounds.height).fill()
        }
    }
}

func hmsShort(_ t: Double) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

func hmsTenths(_ t: Double) -> String {
    let s = Int(t)
    return (s >= 3600 ? String(format: "%d:%02d:", s / 3600, s % 3600 / 60) : String(format: "%d:", s / 60))
        + String(format: "%04.1f", t.truncatingRemainder(dividingBy: 60))
}

final class AudioEditor: NSObject, NSWindowDelegate {
    static var current: AudioEditor?

    let dir: String
    let onDone: ([(Double, Double)]?) -> Void     // nil = cancelled
    private var window: NSWindow!
    private let wave = WaveformView()
    private let scroll = NSScrollView()
    private let info = NSTextField(labelWithString: "")
    private let cutsLabel = NSTextField(labelWithString: "")
    private var player: AVAudioPlayer?
    private var stopAt: Double?
    private var timer: Timer?
    private var zoom: CGFloat = 1
    private var finished = false

    init(dir: String, onDone: @escaping ([(Double, Double)]?) -> Void) {
        self.dir = dir
        self.onDone = onDone
        super.init()
    }

    static func open(dir: String, onDone: @escaping ([(Double, Double)]?) -> Void) {
        let e = AudioEditor(dir: dir, onDone: onDone)
        current = e
        e.build()
        e.load()
    }

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        return b
    }

    private func build(show: Bool = true) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 350), styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MeetRec – " + T("editor_title")
        window.minSize = NSSize(width: 700, height: 340)
        window.delegate = self
        window.isReleasedWhenClosed = false

        let help = NSTextField(wrappingLabelWithString: T("editor_help"))
        help.textColor = .secondaryLabelColor

        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.documentView = wave
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        wave.onSelection = { [weak self] in self?.updateInfo() }

        let zoomSlider = NSSlider(value: 1, minValue: 1, maxValue: 30, target: self, action: #selector(zoomChanged(_:)))
        zoomSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let zoomRow = NSStackView(views: [NSTextField(labelWithString: T("editor_zoom")), zoomSlider, NSView(), info])
        info.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let controls = NSStackView(views: [
            button("▶︎ " + T("editor_play_selection"), #selector(playSelection)),
            button(T("editor_play_from_here"), #selector(playFromHere)),
            button("■ " + T("editor_stop"), #selector(stopPlayback)),
            NSView(),
            button("✂︎ " + T("editor_cut"), #selector(cutSelection)),
            button(T("editor_undo"), #selector(undoCut)),
        ])
        cutsLabel.textColor = .secondaryLabelColor
        cutsLabel.lineBreakMode = .byTruncatingTail

        let apply = button(T("editor_apply"), #selector(applyCuts))
        apply.keyEquivalent = "\r"
        let bottom = NSStackView(views: [cutsLabel, NSView(), button(T("cancel"), #selector(cancel)), apply])

        let stack = NSStackView(views: [help, scroll, zoomRow, controls, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [scroll, zoomRow, controls, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = stack
        window.center()
        info.stringValue = T("editor_loading")
        updateCuts()
        if show {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// README picture: a 30-minute call with one cut and a selection (demo data, nothing shown on screen)
    static func renderDemo(_ path: String) {
        let e = AudioEditor(dir: "", onDone: { _ in })
        e.build(show: false)
        e.window.appearance = NSAppearance(named: .darkAqua)
        e.wave.duration = 1800
        e.wave.peaks = (0..<1800).map { i in
            let x = Double(i)
            let talk = (i / 37) % 7 != 0 ? 1.0 : 0.15
            return talk * (0.35 + 0.25 * sin(x / 5) + 0.2 * sin(x * 1.3)).magnitude
        }
        e.wave.cuts = [(612, 705)]
        e.wave.selection = (1100, 1185)
        e.wave.playhead = 1132
        e.updateCuts(); e.updateInfo()
        e.window.contentView?.layoutSubtreeIfNeeded()
        e.layoutWave()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if let v = e.window.contentView {
            e.window.contentView = NSView()                    // move the content onto a dark offscreen panel
            let box = onDark(v, NSSize(width: 960, height: 350))
            e.layoutWave()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            savePNG(box, path)
        }
    }

    private func load() {
        runMeet(["peaks", dir, "--n", "6000"]) { _, out in
            guard let line = out.split(separator: "\n").last,
                  let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                self.info.stringValue = T("editor_no_audio")
                return
            }
            self.wave.peaks = j["peaks"] as? [Double] ?? []
            self.wave.duration = j["duration"] as? Double ?? 1
            self.player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: self.dir + "/mix.m4a"))
            self.player?.prepareToPlay()
            self.layoutWave()
            self.updateInfo()
        }
    }

    private func layoutWave() {
        let w = max(scroll.contentSize.width, scroll.contentSize.width * zoom)
        wave.frame = NSRect(x: 0, y: 0, width: w, height: scroll.contentSize.height)
        wave.needsDisplay = true
    }

    func windowDidResize(_ n: Notification) { layoutWave() }

    @objc func zoomChanged(_ s: NSSlider) {
        let center = scroll.contentView.bounds.midX / max(wave.bounds.width, 1)
        zoom = CGFloat(s.doubleValue)
        layoutWave()
        scroll.contentView.scroll(to: NSPoint(x: max(0, center * wave.bounds.width - scroll.contentSize.width / 2), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func updateInfo() {
        let total = hmsShort(wave.duration)
        if let (a, b) = wave.selection, b - a > 0.05 {
            info.stringValue = "\(hmsTenths(a)) – \(hmsTenths(b))  (\(hmsTenths(b - a)))  / \(total)"
        } else if let (a, _) = wave.selection {
            info.stringValue = "\(hmsTenths(a))  / \(total)"
        } else {
            info.stringValue = T("editor_total", ["t": total])
        }
    }

    private func updateCuts() {
        let removed = wave.cuts.reduce(0) { $0 + $1.1 - $1.0 }
        cutsLabel.stringValue = wave.cuts.isEmpty ? T("editor_no_cuts")
            : T("editor_cuts", ["n": "\(wave.cuts.count)", "t": hmsTenths(removed)]) + ": "
              + wave.cuts.map { "\(hmsShort($0.0))–\(hmsShort($0.1))" }.joined(separator: ", ")
    }

    // MARK: playback

    private func play(from a: Double, until b: Double?) {
        guard let p = player else { return }
        p.currentTime = a
        p.play()
        stopAt = b
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.wave.playhead = p.currentTime
            if let s = self.stopAt, p.currentTime >= s { self.stopPlayback() }
            if !p.isPlaying { self.timer?.invalidate() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc func playSelection() {
        guard let (a, b) = wave.selection else { return }
        play(from: a, until: b - a > 0.05 ? b : nil)
    }

    @objc func playFromHere() { play(from: wave.selection?.0 ?? 0, until: nil) }

    @objc func stopPlayback() {
        player?.pause()
        timer?.invalidate()
    }

    // MARK: cuts

    @objc func cutSelection() {
        guard let (a, b) = wave.selection, b - a > 0.2 else { NSSound.beep(); return }
        wave.cuts.append((a, b))
        wave.selection = nil
        updateCuts()
    }

    @objc func undoCut() {
        guard !wave.cuts.isEmpty else { return }
        wave.cuts.removeLast()
        updateCuts()
    }

    @objc func applyCuts() { finish(wave.cuts) }
    @objc func cancel() { finish(nil) }

    private func finish(_ result: [(Double, Double)]?) {
        guard !finished else { return }
        finished = true
        stopPlayback()
        window.orderOut(nil)
        onDone(result)
        AudioEditor.current = nil
    }

    func windowWillClose(_ n: Notification) { finish(nil) }
}
