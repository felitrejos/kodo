import CoreAudio
import Foundation

/// A hardware output or input as Core Audio reports it right now.
struct AudioDevice: Identifiable, Hashable, Sendable {
    enum Transport: Sendable {
        case builtIn, bluetooth, airPlay, usb, other
    }

    let id: AudioObjectID
    /// Stable across reconnects and reboots, unlike `id`, so settings are keyed by it.
    let uid: String
    let name: String
    let transport: Transport
    let outputChannels: Int
    let inputChannels: Int

    var isOutput: Bool { outputChannels > 0 }
    var isInput: Bool { inputChannels > 0 }

    var symbolName: String {
        switch transport {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "hifispeaker"
        case .airPlay: "airplayaudio"
        case .usb: "cable.connector"
        case .other: "speaker.wave.2"
        }
    }

    init?(id: AudioObjectID) {
        guard
            let uid = try? id.readString(kAudioDevicePropertyDeviceUID),
            let name = try? id.readString(kAudioObjectPropertyName),
            let transportType = try? id.read(kAudioDevicePropertyTransportType, default: UInt32(0))
        else {
            return nil
        }

        // Aggregates and virtual devices (including our own) are not speakers you can point at.
        guard transportType != kAudioDeviceTransportTypeAggregate, transportType != kAudioDeviceTransportTypeVirtual else {
            return nil
        }

        self.id = id
        self.uid = uid
        self.name = name
        outputChannels = id.streamChannelCounts(scope: kAudioObjectPropertyScopeOutput).reduce(0, +)
        inputChannels = id.streamChannelCounts(scope: kAudioObjectPropertyScopeInput).reduce(0, +)
        transport = switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeUSB: .usb
        default: .other
        }
    }

    static func all() -> [AudioDevice] {
        let ids = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self)) ?? []
        return ids.compactMap(AudioDevice.init(id:))
    }

    var nominalSampleRate: Double {
        (try? id.read(kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
    }

    func supports(sampleRate: Double) -> Bool {
        let ranges = (try? id.readArray(kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self)) ?? []
        return ranges.contains { $0.mMinimum <= sampleRate && sampleRate <= $0.mMaximum }
    }

    func setNominalSampleRate(_ sampleRate: Double) throws {
        guard nominalSampleRate != sampleRate else {
            return
        }
        try id.write(kAudioDevicePropertyNominalSampleRate, Float64(sampleRate))
    }

    /// The built-in microphone is the one that sits where you sit; others are a fallback.
    static func calibrationMicrophone() -> AudioDevice? {
        let inputs = all().filter(\.isInput)
        return inputs.first { $0.transport == .builtIn } ?? inputs.first { $0.transport != .bluetooth } ?? inputs.first
    }
}
