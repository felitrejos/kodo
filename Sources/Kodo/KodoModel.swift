import AVFoundation
import CoreAudio
import KodoCore
import Observation
import ServiceManagement

@MainActor
@Observable
final class KodoModel {
    struct CalibrationProgress: Equatable {
        var output: String
        var fraction: Double
    }

    private(set) var outputs: [AudioDevice] = []
    /// Every app with an audio connection, playing or not.
    private(set) var apps: [AudioApp] = []
    private(set) var isOn = false
    private(set) var calibration: CalibrationProgress?
    /// The last thing that went wrong, shown until the next action succeeds.
    private(set) var problem: String?
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var settings = KodoSettings.load() {
        didSet {
            guard !isPreview else {
                return
            }
            settings.save()
            applyMix()
        }
    }

    /// When each app last played, so pausing a song doesn't make its row vanish at once.
    /// Not observed: it ticks every second while anything plays, and a row expiring a little
    /// late, on the next real change or the next time the menu opens, is fine.
    @ObservationIgnored private var lastHeard: [String: Date] = [:]
    /// How long a paused app keeps its row. Adjusted apps keep theirs while they run.
    private static let pausedAppLinger: TimeInterval = 10 * 60

    @ObservationIgnored private var router: TapRouter?
    @ObservationIgnored private var engine: UnisonEngine?
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?
    @ObservationIgnored private var appWatchTask: Task<Void, Never>?
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private let isPreview: Bool

    init() {
        isPreview = false
        outputs = AudioDevice.all().filter(\.isOutput)
        listenForDeviceChanges()
    }

    /// Fixed sample data for designing the menu without touching any audio.
    init(previewOutputs: [AudioDevice], apps: [AudioApp], settings: KodoSettings, isOn: Bool) {
        isPreview = true
        outputs = previewOutputs
        self.apps = apps
        self.settings = settings
        self.isOn = isOn
        lastHeard = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Date.now) })
    }

    // MARK: - State for the menu

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

    /// Apps worth a row: playing now, played in the last few minutes, or adjusted.
    var visibleApps: [AudioApp] {
        let cutoff = Date.now.addingTimeInterval(-Self.pausedAppLinger)
        return apps.filter { $0.isPlaying || isAdjusted($0) || (lastHeard[$0.id] ?? .distantPast) > cutoff }
            .sorted { lhs, rhs in
                lhs.isPlaying != rhs.isPlaying ? lhs.isPlaying : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
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

    func volume(for output: AudioDevice) -> Float {
        settings.volumes[output.uid] ?? 1
    }

    func volume(for app: AudioApp) -> Float {
        settings.appVolumes[app.id] ?? 1
    }

    func isMuted(_ app: AudioApp) -> Bool {
        settings.mutedApps.contains(app.id)
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

    func toggle(_ output: AudioDevice) {
        if settings.selectedOutputs.remove(output.uid) == nil {
            settings.selectedOutputs.insert(output.uid)
        }
        rebuildIfRunning()
    }

    func setVolume(_ volume: Float, for output: AudioDevice) {
        settings.volumes[output.uid] = volume
    }

    func nudge(_ output: AudioDevice, by seconds: Double) {
        let trim = (settings.trims[output.uid] ?? 0) + seconds
        settings.trims[output.uid] = abs(trim) < 0.0005 ? nil : trim
    }

    func resetTrim(for output: AudioDevice) {
        settings.trims[output.uid] = nil
    }

    func setVolume(_ volume: Float, for app: AudioApp) {
        // Kept even at 100%, so dragging around full volume doesn't keep moving the app
        // between its own tap and the global one.
        settings.appVolumes[app.id] = volume
        // Reaching for the slider means you want to hear it.
        settings.mutedApps.remove(app.id)
        routeApps()
    }

    func toggleMute(_ app: AudioApp) {
        if settings.mutedApps.remove(app.id) == nil {
            settings.mutedApps.insert(app.id)
        }
        routeApps()
    }

    func calibrate() {
        guard !isCalibrating else {
            return
        }
        problem = nil
        calibrationTask = Task { await runCalibration() }
    }

    func cancelCalibration() {
        calibrationTask?.cancel()
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            problem = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Engine

    private func start() {
        guard !isPreview else {
            isOn = true
            return
        }
        guard !activeOutputs.isEmpty else {
            problem = EngineError.noOutputs.localizedDescription
            return
        }
        do {
            refreshApps()
            let router = try router ?? TapRouter()
            _ = try router.route(adjustedApps())
            self.router = router
            let engine = try UnisonEngine(outputs: activeOutputs, taps: router.taps)
            self.engine = engine
            applyMix()
            try engine.start()
            isOn = true
            watchApps()
        } catch {
            stop()
            problem = error.localizedDescription
        }
    }

    private func stop() {
        calibrationTask?.cancel()
        appWatchTask?.cancel()
        engine = nil
        router = nil
        isOn = false
    }

    private func rebuildIfRunning() {
        guard isOn, !isPreview else {
            return
        }
        calibrationTask?.cancel()
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
        engine?.apply(delays: currentDelays(), gains: settings.volumes)
        applyAppGains()
    }

    // MARK: - Apps

    private func isAdjusted(_ app: AudioApp) -> Bool {
        settings.appVolumes[app.id] != nil || settings.mutedApps.contains(app.id)
    }

    private func adjustedApps() -> [AudioApp] {
        apps.filter(isAdjusted)
    }

    /// Gives adjusted apps their own taps, then sets every tap's gain.
    private func routeApps() {
        guard let router, let engine else {
            return
        }
        do {
            if let retired = try router.route(adjustedApps()) {
                try withExtendedLifetime(retired) {
                    try engine.setTaps(router.taps)
                }
            }
        } catch {
            problem = error.localizedDescription
        }
        applyAppGains()
    }

    private func applyAppGains() {
        guard let router, let engine else {
            return
        }
        engine.setGain(1, forInput: 0)
        for app in adjustedApps() {
            guard let input = router.input(for: app.id) else {
                continue
            }
            engine.setGain(isMuted(app) ? 0 : volume(for: app), forInput: input)
        }
    }

    private func refreshApps() {
        let current = AudioAppCatalog.current()
        for app in current where app.isPlaying {
            lastHeard[app.id] = .now
        }
        if current != apps {
            apps = current
        }
    }

    /// Polls while Kodo is on: apps start and stop playing without any notification worth
    /// trusting, and a helper process joining an adjusted app needs to join its tap.
    private func watchApps() {
        appWatchTask?.cancel()
        appWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else {
                    return
                }
                let before = apps
                refreshApps()
                if apps != before {
                    routeApps()
                }
            }
        }
    }

    // MARK: - Calibration

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
            settings.calibratedAt = .now
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
