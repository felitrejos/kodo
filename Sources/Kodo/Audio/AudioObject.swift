import CoreAudio
import Foundation

struct AudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed (\(Self.describe(status)))"
    }

    /// Core Audio statuses are usually four-character codes like 'who?'.
    private static func describe(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            return "error \(status)"
        }
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else {
        throw AudioError(operation: operation(), status: status)
    }
}

/// Thin, typed wrappers over the C property API that every Core Audio object shares.
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func hasProperty(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = Self.address(selector, scope: scope)
        return AudioObjectHasProperty(self, &address)
    }

    func read<Value: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default value: Value
    ) throws -> Value {
        var address = Self.address(selector, scope: scope)
        var result = value
        var size = UInt32(MemoryLayout<Value>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result), "Reading property \(selector)")
        return result
    }

    func readArray<Element>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of _: Element.Type
    ) throws -> [Element] {
        var address = Self.address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "Sizing property \(selector)")
        let count = Int(size) / MemoryLayout<Element>.stride
        guard count > 0 else {
            return []
        }
        return try [Element](unsafeUninitializedCapacity: count) { buffer, initialized in
            try check(
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!),
                "Reading property \(selector)")
            initialized = Int(size) / MemoryLayout<Element>.stride
        }
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "Reading property \(selector)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    func write<Value: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, _ value: Value) throws {
        var address = Self.address(selector)
        var value = value
        try check(
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<Value>.size), &value),
            "Writing property \(selector)")
    }

    /// Channel count of each stream, in the order the IOProc sees the buffers.
    func streamChannelCounts(scope: AudioObjectPropertyScope) -> [Int] {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else {
            return []
        }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
