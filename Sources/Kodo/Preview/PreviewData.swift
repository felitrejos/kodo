import Foundation

/// Sample speakers and apps for SwiftUI previews and screenshots.
@MainActor
enum PreviewData {
    static let speakers = AudioDevice(id: 1, uid: "speakers", name: "MacBook Pro Speakers", transport: .builtIn, outputChannels: 2, inputChannels: 0)
    static let klipsch = AudioDevice(id: 2, uid: "klipsch", name: "Klipsch KD-400", transport: .bluetooth, outputChannels: 2, inputChannels: 0)
    static let airPods = AudioDevice(id: 3, uid: "airpods", name: "AirPods Pro", transport: .bluetooth, outputChannels: 2, inputChannels: 1)
    static let airPodsMax = AudioDevice(id: 5, uid: "airpodsmax", name: "AirPods Max", transport: .bluetooth, outputChannels: 2, inputChannels: 1)
    static let display = AudioDevice(id: 4, uid: "display", name: "LG UltraFine", transport: .display, outputChannels: 2, inputChannels: 0)

    static func app(_ name: String, at path: String, playing: Bool) -> AudioApp {
        AudioApp(id: name, name: name, bundleURL: URL(filePath: path), processes: [], isPlaying: playing)
    }

    static let apps = [
        app("Music", at: "/System/Applications/Music.app", playing: true),
        app("Dia", at: "/Applications/Dia.app", playing: true),
        app("Discord", at: "/Applications/Discord.app", playing: true),
        app("Zoom", at: "/Applications/zoom.us.app", playing: false),
    ]

    static var settings: KodoSettings {
        var settings = KodoSettings()
        var livingRoom = SpeakerGroup(name: "Living Room")
        livingRoom.outputs = ["speakers", "klipsch"]
        livingRoom.measurements = [
            "speakers": Measurement(latency: 0.2685, spread: 0, strength: 0.37),
            "klipsch": Measurement(latency: 0.2496, spread: 0.0002, strength: 0.21),
        ]
        livingRoom.volumes = ["speakers": 0.7, "klipsch": 1]
        livingRoom.calibratedAt = .now.addingTimeInterval(-2 * 86_400)
        var desk = SpeakerGroup(name: "Desk")
        desk.outputs = ["speakers", "airpodsmax"]
        settings.groups = [livingRoom, desk]
        settings.activeGroupID = livingRoom.id
        settings.hiddenOutputs = ["display"]
        settings.appVolumes = ["Dia": 0.45, "Discord": 0.8, "Music": 1.3]
        settings.mutedApps = ["Discord"]
        settings.boostedApps = ["Music"]
        settings.appRoutes = ["Zoom": "airpods"]
        return settings
    }

    static func model(isSyncOn: Bool = true, kodoOutputStatus: KodoOutput.Status = .unavailable) -> KodoModel {
        KodoModel(previewOutputs: [speakers, klipsch, airPods, airPodsMax, display], apps: apps, settings: settings, isSyncOn: isSyncOn, defaultOutputID: klipsch.id, kodoOutputStatus: kodoOutputStatus)
    }
}
