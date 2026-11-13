#if os(macOS)
import CoreAudio
import LainTelemetry
import Synchronization

/// Mutes the Mac's own speakers while its sound plays on the iPad, and puts them back as they were. The
/// capture still hears the sound: it takes it before the output device's mute.
///
/// It mutes the default output device as of `begin`, and `end` unmutes that same device only if `begin`
/// muted it (so a Mac its owner had muted stays muted). If lain dies in between, the Mac stays muted until
/// its owner unmutes it.
public final class OutputMute: Sendable {
    public static let shared = OutputMute()
    private let muted = Mutex<AudioObjectID?>(nil)
    private let log = Telemetry.logger("audio")

    public func begin() {
        muted.withLock { held in
            guard held == nil, let device = Self.defaultOutputDevice(), Self.isMuted(device) == false else { return }
            if Self.setMuted(device, true) {
                held = device
                log.notice("muted the Mac's output while its sound plays on the iPad")
            } else {
                log.notice("this output device can't be muted: the Mac's sound plays here too")
            }
        }
    }

    public func end() {
        muted.withLock { held in
            guard let device = held else { return }
            _ = Self.setMuted(device, false)
            held = nil
        }
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    private static func setMuted(_ device: AudioObjectID, _ on: Bool) -> Bool {
        var address = muteAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
#endif
