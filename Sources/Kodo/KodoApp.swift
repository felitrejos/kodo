import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--list-devices") {
            listDevices()
            return
        }
        if CommandLine.arguments.contains("--list-apps") {
            for app in AudioAppCatalog.current() {
                print("\(app.isPlaying ? "▶︎" : " ") \(app.name) — \(app.id), processes \(app.processes)")
            }
            return
        }
        // A second copy would capture the first one's output and feed it back, so leave.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        guard !others.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
            return
        }
        KodoApp.main()
    }

    /// A quick look at what Kodo sees, without touching any audio.
    private static func listDevices() {
        for device in AudioDevice.all() {
            let roles = [device.isOutput ? "output" : nil, device.isInput ? "input" : nil].compactMap(\.self)
            let volume = device.hardwareVolume.map { " volume \(Int($0 * 100))%" } ?? ""
            print("\(device.name) [\(device.transport)] \(roles.joined(separator: "+")) @ \(Int(device.nominalSampleRate)) Hz\(volume) — \(device.uid)")
        }
        if let microphone = AudioDevice.calibrationMicrophone() {
            print("Calibration microphone: \(microphone.name)")
        }
    }
}

struct KodoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(nsImage: MenuBarIcon.image(delegate.model.menuBarStyle))
                .accessibilityLabel("Kodo")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = KodoModel()

    /// The Speaker Sync control in Control Center switches Sync with a `kodo://` link.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let on = SyncControlState.requestedSync(in: url) {
                model.setSyncOn(on)
            }
        }
    }
}
