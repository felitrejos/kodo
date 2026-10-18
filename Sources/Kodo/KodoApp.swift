import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--list-devices") {
            listDevices()
            return
        }
        if CommandLine.arguments.contains("--smoke-test") {
            MainActor.assumeIsolated { smokeTest() }
            return
        }
        KodoApp.main()
    }

    /// Runs the real engine on every output for a few seconds, without chirps, and reports
    /// whether audio flowed. Whatever is playing keeps playing, routed through Kodo.
    @MainActor
    private static func smokeTest() {
        let outputs = AudioDevice.all().filter(\.isOutput)
        print("Outputs: \(outputs.map(\.name).joined(separator: ", "))")
        do {
            let tap = try SystemAudioTap()
            let engine = try UnisonEngine(outputs: outputs, tap: tap)
            print("Engine at \(Int(engine.sampleRate)) Hz, output streams \(engine.diagnostics.streams)")
            try engine.start()
            RunLoop.main.run(until: .now + 3)
            let diagnostics = engine.diagnostics
            print("Rendered \(diagnostics.cycles) cycles, loudest captured sample \(diagnostics.capturedPeak)")
            engine.stop()
        } catch {
            print("Smoke test failed: \(error.localizedDescription)")
        }
        RunLoop.main.run(until: .now + 0.5)
        print("Sample rates after teardown: \(AudioDevice.all().filter(\.isOutput).map { "\($0.name) \(Int($0.nominalSampleRate))" })")
    }

    /// A quick look at what Kodo sees, without touching any audio.
    private static func listDevices() {
        for device in AudioDevice.all() {
            let roles = [device.isOutput ? "output" : nil, device.isInput ? "input" : nil].compactMap(\.self)
            print("\(device.name) [\(device.transport)] \(roles.joined(separator: "+")) @ \(Int(device.nominalSampleRate)) Hz — \(device.uid)")
        }
        if let microphone = AudioDevice.calibrationMicrophone() {
            print("Calibration microphone: \(microphone.name)")
        }
    }
}

struct KodoApp: App {
    @State private var model = KodoModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.isOn ? "dot.radiowaves.left.and.right" : "hifispeaker.2")
                .accessibilityLabel("Kodo")
        }
        .menuBarExtraStyle(.window)
    }
}
