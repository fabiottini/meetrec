// meetrec-capture: records system audio + microphone with ScreenCaptureKit.
//
// Crash safety: each track is written as raw PCM (s16le, mono) and appended
// as it arrives, so whatever is already on disk can always be recovered,
// even if the process is killed. Conversion to m4a/wav happens later in `meet`.
//
// Usage: meetrec-capture <out_dir> [--no-mic] [--no-system] [--mic-id <AVCaptureDevice uniqueID>]
// Stop with SIGINT/SIGTERM. Writes <out_dir>/<track>.s16 + <track>.json + capture.done

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
}

final class Track {
    let name: String
    let dir: URL
    var handle: FileHandle?
    var sampleRate: Double = 0
    var framesWritten: Int64 = 0
    var startPTS: Double? = nil     // host time (seconds) of the first sample in this track
    var segment = 0
    var lastSync = Date()

    init(name: String, dir: URL) { self.name = name; self.dir = dir }

    var baseName: String { segment == 0 ? name : "\(name)-\(segment)" }

    func open(sampleRate: Double, t0: Double, pts: Double) throws {
        if handle != nil { segment += 1 }   // format changed mid-recording: new segment file
        close()
        self.sampleRate = sampleRate
        framesWritten = 0
        startPTS = pts
        let raw = dir.appendingPathComponent("\(baseName).s16")
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        handle = try FileHandle(forWritingTo: raw)
        let meta: [String: Any] = [
            "format": "s16le", "channels": 1, "sample_rate": Int(sampleRate),
            "offset_seconds": pts - t0,   // relative to the first sample of any track
        ]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("\(baseName).json"))
        log("track \(baseName): \(Int(sampleRate)) Hz, offset \(String(format: "%.3f", pts - t0)) s")
    }

    func write(_ samples: [Int16]) {
        guard let h = handle, !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { h.write(Data(buffer: $0)) }
        framesWritten += Int64(samples.count)
        if Date().timeIntervalSince(lastSync) > 10 { try? h.synchronize(); lastSync = Date() }
    }

    func close() {
        if let h = handle { try? h.synchronize(); try? h.close() }
        handle = nil
    }
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let dir: URL
    let wantMic: Bool
    let wantSystem: Bool
    let micID: String?
    var stream: SCStream?
    let queue = DispatchQueue(label: "meetrec.audio")
    var t0: Double? = nil
    lazy var system = Track(name: "system", dir: self.dir)
    lazy var mic = Track(name: "mic", dir: self.dir)

    init(dir: URL, wantMic: Bool, wantSystem: Bool, micID: String?) {
        self.dir = dir; self.wantMic = wantMic; self.wantSystem = wantSystem; self.micID = micID
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw NSError(domain: "meetrec", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"]) }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        // Video is mandatory for SCStream; keep it as small and rare as possible.
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        cfg.capturesAudio = wantSystem
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        if wantMic {
            cfg.captureMicrophone = true
            if let id = micID { cfg.microphoneCaptureDeviceID = id }
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantSystem { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if wantMic { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await s.startCapture()
        stream = s
        log("recording started in \(dir.path) (system=\(wantSystem), mic=\(wantMic))")
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        queue.sync {
            system.close(); mic.close()
        }
        log("recording stopped")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped with error: \(error.localizedDescription)")
        queue.sync { system.close(); mic.close() }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("capture.error").path,
                                       contents: error.localizedDescription.data(using: .utf8))
        exit(2)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let track: Track
        switch type {
        case .audio: track = system
        case .microphone: track = mic
        default: return
        }
        guard sb.isValid, let fmt = sb.formatDescription?.audioStreamBasicDescription else { return }
        let pts = sb.presentationTimeStamp.seconds
        if t0 == nil { t0 = pts }
        let rate = fmt.mSampleRate

        do {
            if track.handle == nil || track.sampleRate != rate {
                try track.open(sampleRate: rate, t0: t0!, pts: pts)
            }
        } catch { log("cannot open track \(track.name): \(error)"); return }

        // Keep tracks aligned to wall clock: fill gaps with silence.
        let expected = track.startPTS! + Double(track.framesWritten) / rate
        let gap = pts - expected
        if gap > 0.05 {
            let n = Int(gap * rate)
            track.write([Int16](repeating: 0, count: n))
        }

        let samples = Recorder.firstChannelS16(sb, fmt: fmt)
        track.write(samples)
    }

    static func firstChannelS16(_ sb: CMSampleBuffer, fmt: AudioStreamBasicDescription) -> [Int16] {
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return [] }
        var out = [Int16](repeating: 0, count: frames)
        let isFloat = fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let ch = Int(max(fmt.mChannelsPerFrame, 1))
        let stride = nonInterleaved ? 1 : ch
        do {
            try sb.withAudioBufferList { abl, _ in
                guard let first = abl.first, let p = first.mData else { return }
                if isFloat && fmt.mBitsPerChannel == 32 {
                    let f = p.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames {
                        let v = max(-1, min(1, f[i * stride]))
                        out[i] = Int16(v * 32767)
                    }
                } else if !isFloat && fmt.mBitsPerChannel == 16 {
                    let s = p.assumingMemoryBound(to: Int16.self)
                    for i in 0..<frames { out[i] = s[i * stride] }
                } else if !isFloat && fmt.mBitsPerChannel == 32 {
                    let s = p.assumingMemoryBound(to: Int32.self)
                    for i in 0..<frames { out[i] = Int16(truncatingIfNeeded: s[i * stride] >> 16) }
                }
            }
        } catch { return [] }
        return out
    }
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--list-mics" {
    let devs = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                mediaType: .audio, position: .unspecified).devices
    let def = AVCaptureDevice.default(for: .audio)?.uniqueID
    for d in devs { print("\(d.uniqueID == def ? "*" : " ") \(d.localizedName)\t\(d.uniqueID)") }
    exit(0)
}
guard let outPath = args.first, !outPath.hasPrefix("-") else {
    FileHandle.standardError.write("usage: meetrec-capture <out_dir> [--no-mic] [--no-system] [--mic-id ID] | --list-mics\n".data(using: .utf8)!)
    exit(64)
}
args.removeFirst()
var wantMic = true, wantSystem = true
var micID: String? = nil
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--no-mic": wantMic = false
    case "--no-system": wantSystem = false
    case "--mic-id": micID = args.isEmpty ? nil : args.removeFirst()
    default: log("unknown option \(a)"); exit(64)
    }
}

let outDir = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let rec = Recorder(dir: outDir, wantMic: wantMic, wantSystem: wantSystem, micID: micID)

signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN); signal(SIGHUP, SIG_IGN)
var sources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        Task {
            await rec.stop()
            FileManager.default.createFile(atPath: outDir.appendingPathComponent("capture.done").path, contents: nil)
            exit(0)
        }
    }
    src.resume()
    sources.append(src)
}

Task {
    do { try await rec.start() } catch {
        log("cannot start capture: \(error.localizedDescription)")
        log("check System Settings > Privacy & Security > Screen & System Audio Recording and Microphone for your terminal app")
        FileManager.default.createFile(atPath: outDir.appendingPathComponent("capture.error").path,
                                       contents: error.localizedDescription.data(using: .utf8))
        exit(1)
    }
}
dispatchMain()
