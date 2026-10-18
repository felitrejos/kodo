import AVFoundation
import CoreAudio
import KodoCore
import Observation

@MainActor
@Observable
final class KodoModel {
    struct CalibrationProgress: Equatable {
        var output: String
        var fraction: Double
    }

    private(set) var outputs: [AudioDevice] = []
    private(set) var isOn = false
    private(set) var calibration: CalibrationProgress?
    /// The last thing that went wrong, shown until the next action succeeds.
    private(set) var problem: String?
    private(set) var settings = KodoSettings.load() {
        didSet {
            settings.save()
            applyMix()
        }
    }

    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var engine: UnisonEngine?
    /// Calibration or the click test; only one plays at a time.
    @ObservationIgnored private var signalTask: Task<Void, Never>?
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?

    init() {
        outputs = AudioDevice.all().filter(\.isOutput)
        listenForDeviceChanges()
    }

    // MARK: - State for the menu

    private(set) var isTesting = false

    var isCalibrating: Bool {
        calibration != nil
    }

    /// Selected outputs that are connected right now, in the order Core Audio lists them.
    var activeOutputs: [AudioDevice] {
        outputs.filter { settings.selectedOutputs.contains($0.uid) }
    }

    var needsCalibration: Bool {
        activeOutputs.count > 1 && activeOutputs.contains { settings.measurements[$0.uid] == nil }
    }

    func isSelected(_ output: AudioDevice) -> Bool {
        settings.selectedOutputs.contains(output.uid)
    }

    func measurement(for output: AudioDevice) -> Measurement? {
        settings.measurements[output.uid]
    }

    func delay(for output: AudioDevice) -> Double? {
        currentDelays()[output.uid]
    }

    func trim(for output: AudioDevice) -> Double {
        settings.trims[output.uid] ?? 0
    }

    func isMuted(_ output: AudioDevice) -> Bool {
        settings.mutedOutputs.contains(output.uid)
    }

    func volume(for output: AudioDevice) -> Float {
        settings.volumes[output.uid] ?? 1
    }

    // MARK: - Actions

    func setOn(_ on: Bool) {
        problem = nil
        if on {
            start()
        } else {
            stop()
        }
    }

    func setSelected(_ selected: Bool, for output: AudioDevice) {
        if selected {
            settings.selectedOutputs.insert(output.uid)
        } else {
            settings.selectedOutputs.remove(output.uid)
        }
        rebuildIfRunning()
    }

    func setVolume(_ volume: Float, for output: AudioDevice) {
        settings.volumes[output.uid] = volume
        // Reaching for the slider means you want to hear it.
        settings.mutedOutputs.remove(output.uid)
    }

    func toggleMute(_ output: AudioDevice) {
        if settings.mutedOutputs.remove(output.uid) == nil {
            settings.mutedOutputs.insert(output.uid)
        }
    }

    func nudge(_ output: AudioDevice, by seconds: Double) {
        let trim = (settings.trims[output.uid] ?? 0) + seconds
        settings.trims[output.uid] = abs(trim) < 0.0005 ? nil : trim
    }

    func calibrate() {
        guard !isCalibrating, !isTesting else {
            return
        }
        problem = nil
        signalTask = Task { await runCalibration() }
    }

    func cancelCalibration() {
        signalTask?.cancel()
    }

    func playTest() {
        guard !isCalibrating, !isTesting else {
            return
        }
        problem = nil
        signalTask = Task { await runTest() }
    }

    // MARK: - Engine

    private func start() {
        guard !activeOutputs.isEmpty else {
            problem = EngineError.noOutputs.localizedDescription
            return
        }
        do {
            let tap = try tap ?? SystemAudioTap()
            self.tap = tap
            let engine = try UnisonEngine(outputs: activeOutputs, tap: tap)
            self.engine = engine
            applyMix()
            try engine.start()
            isOn = true
        } catch {
            stop()
            problem = error.localizedDescription
        }
    }

    private func stop() {
        signalTask?.cancel()
        engine = nil
        tap = nil
        isOn = false
    }

    private func rebuildIfRunning() {
        guard isOn else {
            return
        }
        signalTask?.cancel()
        engine = nil
        if activeOutputs.isEmpty {
            stop()
        } else {
            start()
        }
    }

    private func currentDelays() -> [String: Double] {
        let active = activeOutputs
        let latencies = Dictionary(uniqueKeysWithValues: active.compactMap { output in
            settings.measurements[output.uid].map { (output.uid, $0.latency) }
        })
        var delays = AlignmentPlan.delays(latencies: latencies, trims: settings.trims)
        // Outputs nobody has measured yet still honour a manual nudge.
        for output in active where delays[output.uid] == nil {
            delays[output.uid] = max(settings.trims[output.uid] ?? 0, 0)
        }
        return delays
    }

    private func applyMix() {
        var gains = settings.volumes
        for uid in settings.mutedOutputs {
            gains[uid] = 0
        }
        engine?.apply(delays: currentDelays(), gains: gains)
    }

    private func runCalibration() async {
        guard await microphoneAllowed() else {
            problem = "Kodo needs the microphone to calibrate. Allow it in System Settings → Privacy & Security → Microphone."
            return
        }
        guard let microphone = AudioDevice.calibrationMicrophone() else {
            problem = "There is no microphone to calibrate with."
            return
        }
        if engine == nil {
            start()
        }
        guard let engine else {
            return
        }

        let calibrator = Calibrator(engine: engine, microphone: microphone)
        calibration = CalibrationProgress(output: "", fraction: 0)
        defer { calibration = nil }
        do {
            let results = try await calibrator.measure { [weak self] output, fraction in
                self?.calibration = CalibrationProgress(output: output.name, fraction: fraction)
            }
            settings.measurements.merge(results) { $1 }
            let missed = engine.outputs.filter { results[$0.uid] == nil }.map(\.name)
            if !missed.isEmpty {
                problem = "Couldn't hear \(missed.formatted(.list(type: .and))). Turn it up or move it closer, then try again."
            }
        } catch is CancellationError {
            // Stopped or rebuilt on purpose; nothing to report.
        } catch {
            problem = error.localizedDescription
        }
    }

    private func runTest() async {
        if engine == nil {
            start()
        }
        guard let engine else {
            return
        }

        isTesting = true
        defer { isTesting = false }
        do {
            try await engine.playTestClicks()
        } catch is CancellationError {
            // Stopped or rebuilt on purpose; nothing to report.
        } catch {
            problem = error.localizedDescription
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    // MARK: - Devices coming and going

    private func listenForDeviceChanges() {
        var address = AudioObjectID.address(kAudioHardwarePropertyDevices)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.devicesChanged()
            }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(.system, &address, .main, listener)
    }

    private func devicesChanged() {
        let current = AudioDevice.all().filter(\.isOutput)
        guard current != outputs else {
            return
        }
        outputs = current

        // A speaker that reconnects gets a new object ID, so compare IDs, not just UIDs.
        if isOn, engine?.outputs.map(\.id) != activeOutputs.map(\.id) {
            rebuildIfRunning()
        }
    }
}
