import Foundation

/// Sample speakers and apps for SwiftUI previews and screenshots.
@MainActor
enum PreviewData {
    static let speakers = AudioDevice(id: 1, uid: "speakers", name: "MacBook Pro Speakers", transport: .builtIn, outputChannels: 2, inputChannels: 0)
    static let klipsch = AudioDevice(id: 2, uid: "klipsch", name: "Klipsch KD-400", transport: .bluetooth, outputChannels: 2, inputChannels: 0)
    static let airPods = AudioDevice(id: 3, uid: "airpods", name: "Felipe’s AirPods Pro", transport: .bluetooth, outputChannels: 2, inputChannels: 1)
    static let display = AudioDevice(id: 4, uid: "display", name: "LG UltraFine", transport: .display, outputChannels: 2, inputChannels: 0)

    static func app(_ name: String, at path: String, playing: Bool) -> AudioApp {
        AudioApp(id: name, name: name, bundleURL: URL(filePath: path), processes: [], isPlaying: playing)
    }

    static let apps = [
        app("Music", at: "/System/Applications/Music.app", playing: true),
        app("Dia", at: "/Applications/Dia.app", playing: true),
        app("Discord", at: "/Applications/Discord.app", playing: true),
        app("Podcasts", at: "/System/Applications/Podcasts.app", playing: false),
    ]

    static var settings: KodoSettings {
        var settings = KodoSettings()
        settings.selectedOutputs = ["speakers", "klipsch"]
        settings.hiddenOutputs = ["display"]
        settings.measurements = [
            "speakers": Measurement(latency: 0.2685, spread: 0, strength: 0.37),
            "klipsch": Measurement(latency: 0.2496, spread: 0.0002, strength: 0.21),
        ]
        settings.volumes = ["speakers": 0.7, "klipsch": 1]
        settings.calibratedAt = .now.addingTimeInterval(-2 * 86_400)
        settings.appVolumes = ["Dia": 0.45, "Discord": 0.8]
        settings.mutedApps = ["Discord"]
        return settings
    }

    static func model(isSyncOn: Bool = true) -> KodoModel {
        KodoModel(previewOutputs: [speakers, klipsch, airPods, display], apps: apps, settings: settings, isSyncOn: isSyncOn, defaultOutputID: klipsch.id)
    }
}
