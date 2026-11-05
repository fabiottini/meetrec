// Hardware input volume of a microphone (Core Audio), shared by the recorder and the menu bar app.
// Not every device exposes it (Bluetooth headsets in call mode often do not).

import CoreAudio
import Foundation

enum MicVolume {
    static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }

    /// Core Audio device for a UID (same string as AVCaptureDevice.uniqueID), or the default input.
    static func deviceID(uid: String?) -> AudioDeviceID? {
        if let uid, !uid.isEmpty {
            var id = AudioDeviceID(0)
            var cf = uid as CFString
            var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let st = withUnsafeMutablePointer(to: &cf) {
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                           UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
            }
            if st == noErr, id != 0 { return id }
        }
        var id = AudioDeviceID(0)
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// Elements that carry an input volume (master first, else per channel).
    static func elements(_ dev: AudioDeviceID) -> [UInt32] {
        for set in [[UInt32(0)], [1, 2], [1]] {
            let ok = set.allSatisfy { el in
                var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
                var settable: DarwinBoolean = false
                return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &settable) == noErr && settable.boolValue
            }
            if ok { return set }
        }
        return []
    }

    static func get(_ dev: AudioDeviceID) -> Float? {
        guard let el = elements(dev).first else { return nil }
        var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func set(_ dev: AudioDeviceID, _ value: Float) -> Bool {
        let els = elements(dev)
        guard !els.isEmpty else { return false }
        var v = Float32(max(0, min(1, value)))
        var ok = true
        for el in els {
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
            ok = ok && AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
        }
        return ok
    }

    // MARK: mute (input scope). Not every device has it: callers fall back to volume 0.

    static func canMute(_ dev: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &settable) == noErr && settable.boolValue
    }

    static func isMuted(_ dev: AudioDeviceID) -> Bool? {
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v != 0 : nil
    }

    @discardableResult
    static func setMute(_ dev: AudioDeviceID, _ on: Bool) -> Bool {
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        var v = UInt32(on ? 1 : 0)
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    static func uid(_ dev: AudioDeviceID) -> String? {
        var a = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }

    static func name(_ dev: AudioDeviceID) -> String {
        var a = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr, let n = name else { return "?" }
        return n.takeRetainedValue() as String
    }
}

/// Lowers the input volume when the mic clips. Never raises it.
final class AutoGain {
    let dev: AudioDeviceID?
    var enabled: Bool
    var last = Date.distantPast
    var onChange: ((Float) -> Void)?

    init(uid: String?, enabled: Bool) { dev = MicVolume.deviceID(uid: uid); self.enabled = enabled }

    /// call with the number of clipped samples seen in the last ~100 ms
    func observe(clipped: Int) {
        guard enabled, clipped >= 3, let dev, Date().timeIntervalSince(last) > 2,
              let v = MicVolume.get(dev), v > 0.1 else { return }
        last = Date()
        let nv = max(0.1, v * 0.85)
        if MicVolume.set(dev, nv) { onChange?(nv) }
    }
}
