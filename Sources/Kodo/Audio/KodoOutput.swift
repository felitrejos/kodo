import AppKit
import CoreAudio

/// Kodo's entry in the Mac's Sound output list. It comes from a small audio driver that Kodo
/// installs on request: picking "Kodo" in Control Center turns Speaker Sync on, and picking
/// any other output turns it off. The device plays nothing itself; Kodo captures every app
/// with its tap and plays the group, and passes the device's volume and mute on to it.
enum KodoOutput {
    enum Status {
        /// Built without the driver, as with `swift run`.
        case unavailable
        case notInstalled
        /// An older driver than the one in this copy of Kodo.
        case outdated
        case installed
    }

    /// Matches kDeviceUID in Driver/KodoDriver.c.
    static let deviceUID = "KodoDevice"
    private static let pluginsFolder = URL(filePath: "/Library/Audio/Plug-Ins/HAL")
    private static let installedURL = pluginsFolder.appending(path: "Kodo.driver")

    private static var bundledURL: URL? {
        Bundle.main.url(forResource: "Kodo", withExtension: "driver")
    }

    static var status: Status {
        guard bundledURL != nil else {
            return .unavailable
        }
        guard let installed = version(at: installedURL) else {
            return .notInstalled
        }
        return installed == bundledVersion ? .installed : .outdated
    }

    /// The version of the driver this copy of Kodo carries.
    static var bundledVersion: String? {
        bundledURL.flatMap(version(at:))
    }

    private static func version(at url: URL) -> String? {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// The device, while the driver is loaded.
    static func device() -> AudioDevice? {
        var address = AudioObjectID.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = deviceUID as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else {
            return nil
        }
        return AudioDevice(id: id, uid: deviceUID, name: "Kodo", transport: .other, outputChannels: 2, inputChannels: 0)
    }

    /// Copies the driver into place and restarts Core Audio so it loads. Asks for an
    /// administrator's password, since the folder belongs to the system.
    static func install() async throws {
        guard let bundledURL else {
            throw KodoOutputError.missing
        }
        try await runAsAdministrator(prompt: "Kodo wants to add itself to your Sound output list.", """
            mkdir -p \(quoted(pluginsFolder.path)) && \
            rm -rf \(quoted(installedURL.path)) && \
            cp -R \(quoted(bundledURL.path)) \(quoted(installedURL.path)) && \
            killall coreaudiod
            """)
    }

    static func uninstall() async throws {
        try await runAsAdministrator(prompt: "Kodo wants to remove itself from your Sound output list.", "rm -rf \(quoted(installedURL.path)) && killall coreaudiod")
    }

    /// Core Audio's restart leaves every device and tap Kodo holds behind, so the cleanest
    /// way back is a fresh start.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \(quoted(Bundle.main.bundlePath))"]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacing("'", with: "'\\''") + "'"
    }

    private static func runAsAdministrator(prompt: String, _ command: String) async throws {
        let escaped = command.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // -128 is the password prompt's Cancel button.
            throw message.contains("-128") ? KodoOutputError.cancelled : KodoOutputError.failed
        }
    }
}

enum KodoOutputError: LocalizedError {
    case missing, cancelled, failed

    var errorDescription: String? {
        switch self {
        case .missing: "This copy of Kodo doesn't include its output."
        case .cancelled: nil
        case .failed: "Couldn't set up Kodo's output."
        }
    }
}
