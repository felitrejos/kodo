import AppKit
import CoreAudio

/// Lists the apps Core Audio knows about, grouping helper processes under their app.
enum AudioAppCatalog {
    static func current() -> [AudioApp] {
        let processes = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)) ?? []
        let appsByPID = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { _, latest in latest })
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var grouped: [pid_t: (app: NSRunningApplication, processes: [AudioObjectID], playing: Bool)] = [:]
        for process in processes {
            guard
                let pid = try? process.read(kAudioProcessPropertyPID, default: pid_t(0)),
                pid != ownPID,
                let app = owningApp(of: pid, in: appsByPID),
                app.processIdentifier != ownPID,
                // Another copy of Kodo plays what it captured; never offer to tap that.
                app.bundleIdentifier != Bundle.main.bundleIdentifier ?? "com.felipetrejos.kodo",
                // Finder, Control Center and friends only make interface sounds; they stay
                // in the global tap at full volume rather than cluttering the list.
                app.bundleURL?.path.hasPrefix("/System/Library/CoreServices/") != true
            else {
                continue
            }
            let playing = ((try? process.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
            var entry = grouped[app.processIdentifier] ?? (app, [], false)
            entry.processes.append(process)
            entry.playing = entry.playing || playing
            grouped[app.processIdentifier] = entry
        }

        return grouped.values.map { entry in
            AudioApp(
                id: entry.app.bundleIdentifier ?? "pid-\(entry.app.processIdentifier)",
                name: entry.app.localizedName ?? "Unknown",
                bundleURL: entry.app.bundleURL,
                processes: entry.processes.sorted(),
                isPlaying: entry.playing)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The .app a process belongs to. System daemons have none and are left out, so their
    /// sounds stay in the global tap at full volume.
    private static func owningApp(of pid: pid_t, in appsByPID: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        let candidates = [responsiblePID(for: pid), pid].compactMap { $0.flatMap { appsByPID[$0] } }
        guard let app = candidates.first(where: { $0.bundleURL?.pathExtension == "app" }) else {
            return nil
        }
        // Electron and Chromium helpers are apps nested inside the real one, like
        // Dia.app/Contents/Frameworks/…/Dia Helper.app. Credit the outermost app.
        guard let outer = outermostApp(containing: app.bundleURL) else {
            return app
        }
        return appsByPID.values.first { $0.bundleURL?.standardizedFileURL == outer } ?? app
    }

    private static func outermostApp(containing url: URL?) -> URL? {
        guard let url else {
            return nil
        }
        let components = url.standardizedFileURL.pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }), index < components.count - 1 else {
            return nil
        }
        return URL(filePath: NSString.path(withComponents: Array(components[...index])), directoryHint: .isDirectory).standardizedFileURL
    }

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// Helpers such as Safari's WebContent processes are launched by launchd, not their app,
    /// so walking parent processes can't find the app. macOS tracks who is responsible for
    /// each process through a private but long-standing call.
    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsiblePIDFunction else {
            return nil
        }
        let responsible = function(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }
}
