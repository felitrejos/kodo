import CoreAudio

/// The technical facts the device inspector shows, read fresh each time it opens.
struct DeviceDetails: Equatable {
    var connection: String
    var manufacturer: String?
    var sampleRate: Double
    var availableSampleRates: [Double]
    var outputChannels: Int
    var inputChannels: Int
    var bitDepth: Int?
    var isFloat: Bool
    /// What the device says its output delay is. Bluetooth tends to report less than it has,
    /// which is why Kodo measures instead.
    var reportedLatency: Double?

    private static let standardRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    init(device: AudioDevice) {
        let id = device.id
        let transport = (try? id.read(kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
        connection = Self.describe(transport: transport)
        manufacturer = (try? id.readString(kAudioObjectPropertyManufacturer)).flatMap { $0.isEmpty ? nil : $0 }
        sampleRate = device.nominalSampleRate
        let ranges = (try? id.readArray(kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self)) ?? []
        availableSampleRates = Self.standardRates.filter { rate in ranges.contains { $0.mMinimum <= rate && rate <= $0.mMaximum } }
        outputChannels = device.outputChannels
        inputChannels = device.inputChannels

        let streams = (try? id.readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioObjectID.self)) ?? []
        let format = streams.first.flatMap { try? $0.read(kAudioStreamPropertyPhysicalFormat, default: AudioStreamBasicDescription()) }
        bitDepth = format.map { Int($0.mBitsPerChannel) }.flatMap { $0 > 0 ? $0 : nil }
        isFloat = format.map { $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 } ?? false

        let deviceLatency = (try? id.read(kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput, default: UInt32(0))) ?? 0
        let safetyOffset = (try? id.read(kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput, default: UInt32(0))) ?? 0
        let streamLatency = streams.first.flatMap { try? $0.read(kAudioStreamPropertyLatency, default: UInt32(0)) } ?? 0
        let frames = Double(deviceLatency + safetyOffset + streamLatency)
        reportedLatency = sampleRate > 0 && frames > 0 ? frames / sampleRate : nil
    }

    private static func describe(transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeBluetooth: "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypePCI: "PCI"
        case kAudioDeviceTransportTypeFireWire: "FireWire"
        case kAudioDeviceTransportTypeAVB: "AVB"
        default: "Other"
        }
    }
}
