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

    /// What the engine has to be running, if anything. Rebuilding the engine is only needed
    /// when this changes; app volumes and mutes change in place.
    private struct EngineSetup: Equatable {
        var outputs: [AudioObjectID]
        /// Speaker Sync captures every app; otherwise only the apps you adjusted.
        var capturesEverything: Bool
    }

    private(set) var outputs: [AudioDevice] = []
    private(set) var defaultOutputID: AudioObjectID?
    /// The current output's own volume, for the slider when Sync is off.
    private(set) var defaultOutputVolume: Float?
    private(set) var defaultOutputMuted: Bool?
    /// Every app with an audio connection, playing or not.
    private(set) var apps: [AudioApp] = []
    private(set) var isSyncOn = false
    private(set) var calibration: CalibrationProgress?
    /// The last thing that went wrong, shown until the next action succeeds.
    private(set) var problem: String?
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    var showsHiddenOutputs = false
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
    @ObservationIgnored private var runningSetup: EngineSetup?
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?
    @ObservationIgnored private var appWatchTask: Task<Void, Never>?
    /// Apps resting at full volume, waiting to be handed back to macOS untouched.
    @ObservationIgnored private var releaseTasks: [String: Task<Void, Never>] = [:]
    /// How long an app has to sit at 100% before Kodo stops capturing it. Long enough that
    /// dragging around full volume doesn't keep tapping and untapping the app.
    private static let releaseDelay: Duration = .seconds(2)
    @ObservationIgnored private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private let isPreview: Bool

    init() {
        isPreview = false
        outputs = AudioDevice.all().filter(\.isOutput)
        isSyncOn = settings.syncEnabled && !activeOutputs.isEmpty
        // An app left at full volume needs nothing from Kodo; don't capture it at launch.
        settings.appVolumes = settings.appVolumes.filter { id, volume in !Self.isFullVolume(volume) || settings.mutedApps.contains(id) }
        refreshDefaultOutput()
        refreshApps()
        listenForDeviceChanges()
        watchApps()
        reconcileEngine()
    }

    /// Fixed sample data for designing the menu without touching any audio.
    init(previewOutputs: [AudioDevice], apps: [AudioApp], settings: KodoSettings, isSyncOn: Bool, defaultOutputID: AudioObjectID?) {
        isPreview = true
        outputs = previewOutputs
        self.apps = apps
        self.settings = settings
        self.isSyncOn = isSyncOn
        self.defaultOutputID = defaultOutputID
        defaultOutputVolume = 0.6
        defaultOutputMuted = false
        lastHeard = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Date.now) })
    }

    // MARK: - State for the menu

    var isCalibrating: Bool {
        calibration != nil
    }

    /// Outputs to list: everything connected, minus the ones you hid.
    var listedOutputs: [AudioDevice] {
        outputs.filter { showsHiddenOutputs || !isHidden($0) }
    }

    var hiddenOutputCount: Int {
        outputs.filter(isHidden).count
    }

    /// Selected outputs that are connected right now, in the order Core Audio lists them.
    var activeOutputs: [AudioDevice] {
        outputs.filter { settings.selectedOutputs.contains($0.uid) && !isHidden($0) }
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

    /// Whether a speaker is lit: part of the group with Sync on, the Mac's output with it off.
    func isActive(_ output: AudioDevice) -> Bool {
        isSyncOn ? isSelected(output) : output.id == defaultOutputID
    }

    func isSelected(_ output: AudioDevice) -> Bool {
        settings.selectedOutputs.contains(output.uid)
    }

    func isHidden(_ output: AudioDevice) -> Bool {
        settings.hiddenOutputs.contains(output.uid)
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

    /// The slider value for a speaker row: Kodo's own level with Sync on, the device's
    /// volume with it off.
    func volume(for output: AudioDevice) -> Float? {
        if isSyncOn {
            return settings.volumes[output.uid] ?? 1
        }
        return output.id == defaultOutputID ? defaultOutputVolume : nil
    }

    func isMuted(_ output: AudioDevice) -> Bool {
        if isSyncOn {
            return settings.mutedOutputs.contains(output.uid)
        }
        return output.id == defaultOutputID && defaultOutputMuted == true
    }

    func volume(for app: AudioApp) -> Float {
        settings.appVolumes[app.id] ?? 1
    }

    func isMuted(_ app: AudioApp) -> Bool {
        settings.mutedApps.contains(app.id)
    }

    // MARK: - Speaker actions

    func setSyncOn(_ on: Bool) {
        problem = nil
        isSyncOn = on && !activeOutputs.isEmpty
        settings.syncEnabled = isSyncOn
        reconcileEngine()
    }

    /// With Sync on, adds or removes the speaker from the group. With it off, plays through it.
    func choose(_ output: AudioDevice) {
        problem = nil
        if isSyncOn {
            if settings.selectedOutputs.remove(output.uid) == nil {
                settings.selectedOutputs.insert(output.uid)
            }
            if activeOutputs.isEmpty {
                isSyncOn = false
            }
            reconcileEngine()
        } else {
            guard !isPreview else {
                defaultOutputID = output.id
                return
            }
            do {
                try output.makeDefaultOutput()
            } catch {
                problem = "Couldn't switch to \(output.name)."
            }
        }
    }

    func setVolume(_ volume: Float, for output: AudioDevice) {
        if isSyncOn {
            settings.volumes[output.uid] = volume
            settings.mutedOutputs.remove(output.uid)
        } else {
            if defaultOutputMuted == true {
                defaultOutputMuted = false
                if !isPreview {
                    output.setHardwareMute(false)
                }
            }
            defaultOutputVolume = volume
            if !isPreview {
                output.setHardwareVolume(volume)
            }
        }
    }

    func toggleMute(_ output: AudioDevice) {
        if isSyncOn {
            if settings.mutedOutputs.remove(output.uid) == nil {
                settings.mutedOutputs.insert(output.uid)
            }
            return
        }
        let muted = !(defaultOutputMuted ?? false)
        defaultOutputMuted = muted
        if !isPreview {
            output.setHardwareMute(muted)
        }
    }

    func nudge(_ output: AudioDevice, by seconds: Double) {
        let trim = (settings.trims[output.uid] ?? 0) + seconds
        settings.trims[output.uid] = abs(trim) < 0.0005 ? nil : trim
    }

    func resetTrim(for output: AudioDevice) {
        settings.trims[output.uid] = nil
    }

    func setHidden(_ hidden: Bool, for output: AudioDevice) {
        if hidden {
            settings.hiddenOutputs.insert(output.uid)
        } else {
            settings.hiddenOutputs.remove(output.uid)
        }
        if hiddenOutputCount == 0 {
            showsHiddenOutputs = false
        }
        if isSyncOn, activeOutputs.isEmpty {
            isSyncOn = false
        }
        reconcileEngine()
    }

    func setSampleRate(_ rate: Double, for output: AudioDevice) {
        do {
            try output.setNominalSampleRate(rate)
        } catch {
            problem = "\(output.name) can't switch to that sample rate right now."
        }
        // The engine settled on a shared rate when it started; let it settle again.
        if engine?.outputs.contains(output) == true {
            restartEngine()
        }
    }

    // MARK: - App actions

    func setVolume(_ volume: Float, for app: AudioApp) {
        settings.appVolumes[app.id] = volume
        // Reaching for the slider means you want to hear it.
        settings.mutedApps.remove(app.id)
        reconcileEngine()
        scheduleRelease(of: app)
    }

    private static func isFullVolume(_ volume: Float) -> Bool {
        volume >= 0.995
    }

    /// Once an app has rested at 100% and unmuted for a moment, stops capturing it, so Kodo
    /// only records system audio while something actually needs it.
    private func scheduleRelease(of app: AudioApp) {
        releaseTasks[app.id]?.cancel()
        guard Self.isFullVolume(volume(for: app)), !isMuted(app) else {
            releaseTasks[app.id] = nil
            return
        }
        releaseTasks[app.id] = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseDelay)
            guard let self, !Task.isCancelled, Self.isFullVolume(volume(for: app)), !isMuted(app) else {
                return
            }
            releaseTasks[app.id] = nil
            reset(app)
        }
    }

    func toggleMute(_ app: AudioApp) {
        if settings.mutedApps.remove(app.id) == nil {
            settings.mutedApps.insert(app.id)
        }
        reconcileEngine()
        scheduleRelease(of: app)
    }

    /// Puts the app back to normal: full volume, unmuted, untapped.
    func reset(_ app: AudioApp) {
        settings.appVolumes[app.id] = nil
        settings.mutedApps.remove(app.id)
        reconcileEngine()
    }

    // MARK: - Calibration

    func calibrate() {
        guard !isCalibrating, isSyncOn else {
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

    private var neededSetup: EngineSetup? {
        if isSyncOn, !activeOutputs.isEmpty {
            return EngineSetup(outputs: activeOutputs.map(\.id), capturesEverything: true)
        }
        guard !adjustedApps().isEmpty, let defaultOutputID, outputs.contains(where: { $0.id == defaultOutputID }) else {
            return nil
        }
        return EngineSetup(outputs: [defaultOutputID], capturesEverything: false)
    }

    /// Starts, stops, or rebuilds the engine to match what's needed, then routes the apps.
    private func reconcileEngine() {
        guard !isPreview else {
            return
        }
        let needed = neededSetup
        guard needed != runningSetup else {
            routeApps()
            return
        }
        stopEngine()
        guard let needed else {
            return
        }
        do {
            let router = try TapRouter(capturesEverything: needed.capturesEverything)
            _ = try router.route(adjustedApps())
            let engine = try UnisonEngine(outputs: needed.outputs.compactMap { id in outputs.first { $0.id == id } }, taps: router.taps)
            self.router = router
            self.engine = engine
            applyMix()
            try engine.start()
            runningSetup = needed
        } catch {
            stopEngine()
            isSyncOn = false
            problem = error.localizedDescription
        }
    }

    private func restartEngine() {
        stopEngine()
        reconcileEngine()
    }

    private func stopEngine() {
        calibrationTask?.cancel()
        engine = nil
        router = nil
        runningSetup = nil
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
        guard let engine else {
            return
        }
        if runningSetup?.capturesEverything ?? isSyncOn {
            var gains = settings.volumes
            for uid in settings.mutedOutputs {
                gains[uid] = 0
            }
            engine.apply(delays: currentDelays(), gains: gains)
        } else {
            // A single output needs no delay, and its volume is the device's own.
            engine.apply(delays: [:], gains: [:])
        }
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
        if router.capturesEverything {
            engine.setGain(1, forInput: 0)
        }
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

    /// Polls once a second: apps start and stop playing without a notification worth
    /// trusting, a helper process joining an adjusted app needs to join its tap, and the
    /// volume keys change the output's volume behind Kodo's back.
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
                    reconcileEngine()
                }
                refreshDefaultOutputVolume()
            }
        }
    }

    // MARK: - Calibration run

    private func runCalibration() async {
        guard await microphoneAllowed() else {
            problem = "Kodo needs the microphone to calibrate. Allow it in System Settings → Privacy & Security → Microphone."
            return
        }
        guard let microphone = AudioDevice.calibrationMicrophone() else {
            problem = "There is no microphone to calibrate with."
            return
        }
        guard let engine, runningSetup?.capturesEverything == true else {
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
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectID.address(selector)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.devicesChanged()
                }
            }
            listeners.append((address, listener))
            AudioObjectAddPropertyListenerBlock(.system, &address, .main, listener)
        }
    }

    private func devicesChanged() {
        let current = AudioDevice.all().filter(\.isOutput)
        if current != outputs {
            outputs = current
        }
        refreshDefaultOutput()
        if isSyncOn, activeOutputs.isEmpty {
            isSyncOn = false
        }
        // A speaker that reconnects gets a new object ID, which changes the needed setup.
        reconcileEngine()
    }

    private func refreshDefaultOutput() {
        let id = AudioDevice.defaultOutputID
        if id != defaultOutputID {
            defaultOutputID = id
        }
        refreshDefaultOutputVolume()
    }

    private func refreshDefaultOutputVolume() {
        let output = outputs.first { $0.id == defaultOutputID }
        let volume = output?.hardwareVolume
        if volume != defaultOutputVolume {
            defaultOutputVolume = volume
        }
        let muted = output?.hardwareMute
        if muted != defaultOutputMuted {
            defaultOutputMuted = muted
        }
    }
}
