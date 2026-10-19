import CoreAudio
import Foundation

/// A muted Core Audio process tap. Apps keep playing, but nothing they play reaches the
/// speakers directly; Kodo replays the captured audio through every output with its own delay.
/// Destroying the tap, or Kodo quitting, unmutes them again.
///
/// Kodo runs one global tap for everything at full volume, plus one tap per app whose volume
/// you changed. The global tap excludes those apps, so each sound is captured exactly once.
final class SystemAudioTap {
    let id: AudioObjectID
    let uid: String

    /// Everything the Mac plays, except Kodo and `excluded`.
    static func everything(excluding excluded: [AudioObjectID] = []) throws -> SystemAudioTap {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: try ownProcessList() + excluded)
        return try SystemAudioTap(description: description, name: "Kodo system audio")
    }

    /// Only what these processes play, mixed to stereo.
    static func app(_ processes: [AudioObjectID], name: String) throws -> SystemAudioTap {
        try SystemAudioTap(description: CATapDescription(stereoMixdownOfProcesses: processes), name: "Kodo \(name)")
    }

    private init(description: CATapDescription, name: String) throws {
        description.name = name
        description.isPrivate = true
        description.muteBehavior = .muted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the \(name) tap")
        id = tapID
        uid = description.uuid.uuidString
    }

    deinit {
        AudioHardwareDestroyProcessTap(id)
    }

    /// Kodo's own process, so the global tap never captures what Kodo plays.
    private static func ownProcessList() throws -> [AudioObjectID] {
        let object = try processObject(for: ProcessInfo.processInfo.processIdentifier)
        // Without the exclusion the global tap would capture Kodo's own output and feed it
        // back forever, so refuse rather than guess.
        guard object != kAudioObjectUnknown else {
            throw AudioError(operation: "Finding Kodo's own audio process", status: kAudioHardwareBadObjectError)
        }
        return [object]
    }

    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectID.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
            "Finding an audio process")
        return object
    }
}
