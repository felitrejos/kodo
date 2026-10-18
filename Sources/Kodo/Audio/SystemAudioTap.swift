import CoreAudio
import Foundation

/// A Core Audio process tap on everything the Mac plays, except Kodo itself.
///
/// The tap is muted: apps keep playing, but nothing reaches the speakers directly. Kodo
/// replays the captured mix through every output with its own delay. Destroying the tap,
/// or Kodo quitting, unmutes the system again.
final class SystemAudioTap {
    let id: AudioObjectID
    let uid: String

    init() throws {
        let ownProcess = try Self.processObject(for: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.name = "Kodo system audio"
        description.isPrivate = true
        description.muteBehavior = .muted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the system audio tap")
        id = tapID
        uid = description.uuid.uuidString
    }

    deinit {
        AudioHardwareDestroyProcessTap(id)
    }

    private static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectID.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
            "Finding Kodo's own audio process")
        return object
    }
}
