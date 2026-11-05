// "Mute microphone": a manual switch that mutes the mic for every app (off by default).
// Forced: re-applied every second, also on a newly selected default input.
// Uses the device mute when there is one, otherwise input volume 0 (the old volume is restored).
// Restored when switched off or when the app quits.

import CoreAudio
import Foundation

final class MicMute {
    static let shared = MicMute()

    /// user choice, survives restarts
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "micMuteEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "micMuteEnabled") }
    }

    /// devices muted by us: uid -> previous volume (-1 = muted with the mute property).
    /// Saved, so a crash does not leave a device silent forever: the next start restores it.
    private var mutedByUs: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "micMutedDevices") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "micMutedDevices") }
    }

    /// true when the current mic cannot be muted by macOS (no mute, no adjustable volume)
    private(set) var unsupported = false

    var isActive: Bool { enabled && !mutedByUs.isEmpty }

    func tick(micUID: String?) {
        guard enabled else { restoreAll(); return }
        guard let dev = MicVolume.deviceID(uid: micUID), let uid = MicVolume.uid(dev) else { return }
        var muted = mutedByUs
        if MicVolume.canMute(dev) {
            if MicVolume.isMuted(dev) != true { MicVolume.setMute(dev, true) }
            if muted[uid] == nil { muted[uid] = -1 }
            unsupported = false
        } else if let v = MicVolume.get(dev) {
            if muted[uid] == nil { muted[uid] = Double(v) }      // remember the volume once
            if v > 0 { MicVolume.set(dev, 0) }                    // forced: put it back to 0
            unsupported = false
        } else {
            unsupported = true
        }
        if muted != mutedByUs { mutedByUs = muted }
    }

    func restoreAll() {
        let muted = mutedByUs
        guard !muted.isEmpty else { return }
        for (uid, prev) in muted {
            guard let dev = MicVolume.deviceID(uid: uid), MicVolume.uid(dev) == uid else { continue }
            if prev < 0 { MicVolume.setMute(dev, false) } else { MicVolume.set(dev, Float(prev)) }
        }
        mutedByUs = [:]
    }
}
