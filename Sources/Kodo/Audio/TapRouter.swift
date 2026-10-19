import CoreAudio

/// Decides which taps feed the engine.
///
/// With Speaker Sync on, one global tap captures every app at full volume and each app you
/// adjusted gets a tap of its own; the global tap excludes those apps, so nothing is heard
/// twice. With Sync off there is no global tap: only adjusted apps are captured, and
/// everything else plays straight to the Mac's output as usual.
///
/// A tap's exclusions can't change while it's in use, so a change builds a new global tap and
/// swaps the whole list at once. The aggregate keeps running through the swap, so the delay
/// buffers, and everything you're listening to, carry on uninterrupted.
@MainActor
final class TapRouter {
    private struct AppTap {
        let appID: String
        let processes: [AudioObjectID]
        let tap: SystemAudioTap
    }

    private var global: SystemAudioTap?
    private var appTaps: [AppTap] = []

    init(capturesEverything: Bool) throws {
        global = capturesEverything ? try .everything() : nil
    }

    var capturesEverything: Bool {
        global != nil
    }

    /// In the order the renderer sees them: the global tap if any, then one per adjusted app.
    var taps: [SystemAudioTap] {
        (global.map { [$0] } ?? []) + appTaps.map(\.tap)
    }

    /// The renderer input carrying an app, if it has a tap of its own.
    func input(for appID: String) -> Int? {
        appTaps.firstIndex { $0.appID == appID }.map { $0 + (capturesEverything ? 1 : 0) }
    }

    /// Gives exactly these apps their own taps. When anything changed, returns the taps it
    /// replaced: keep them alive until the engine has switched to the new `taps`, so the
    /// aggregate never loses an input midway.
    func route(_ apps: [AudioApp]) throws -> [SystemAudioTap]? {
        let unchanged = apps.count == appTaps.count
            && zip(apps, appTaps).allSatisfy { $0.id == $1.appID && $0.processes == $1.processes }
        guard !unchanged else {
            return nil
        }

        let newTaps = try apps.map { app in
            try appTaps.first { $0.appID == app.id && $0.processes == app.processes }
                ?? AppTap(appID: app.id, processes: app.processes, tap: .app(app.processes, name: app.name))
        }
        let retired = taps
        if capturesEverything {
            global = try .everything(excluding: newTaps.flatMap(\.processes))
        }
        appTaps = newTaps
        return retired
    }
}
