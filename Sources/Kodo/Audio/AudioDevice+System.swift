import AudioToolbox
import CoreAudio

/// The Mac's own output setting and each device's hardware volume: what Control Center's
/// Sound module changes.
extension AudioDevice {
    static var defaultOutputID: AudioObjectID? {
        let id = (try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))) ?? 0
        return id == kAudioObjectUnknown ? nil : id
    }

    func makeDefaultOutput() throws {
        try AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, id)
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectID.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    }

    /// The device's own volume, if it has one you can set. Many HDMI and some USB devices don't.
    var hardwareVolume: Float? {
        var address = Self.volumeAddress
        var settable: DarwinBoolean = false
        guard
            AudioObjectHasProperty(id, &address),
            AudioObjectIsPropertySettable(id, &address, &settable) == noErr,
            settable.boolValue
        else {
            return nil
        }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return volume
    }

    func setHardwareVolume(_ volume: Float) {
        var address = Self.volumeAddress
        var volume = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectID.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
    }

    /// The device's own mute switch, if it has one.
    var hardwareMute: Bool? {
        var address = Self.muteAddress
        var settable: DarwinBoolean = false
        guard
            AudioObjectHasProperty(id, &address),
            AudioObjectIsPropertySettable(id, &address, &settable) == noErr,
            settable.boolValue
        else {
            return nil
        }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }

    func setHardwareMute(_ muted: Bool) {
        var address = Self.muteAddress
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
