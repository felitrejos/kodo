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

    /// Where an app's sound goes: wherever Kodo plays, or one speaker of your choosing.
    enum Destination: Hashable {
        case kodo
        case device(uid: String)
    }

    /// What one engine has to be running. Rebuilding is only needed when this changes; app
    /// volumes and mutes change in place.
    private struct EngineSetup: Equatable {
        var outputs: [AudioObjectID]
        /// Speaker Sync captures every app; otherwise only the apps sent to this engine.
        var capturesEverything: Bool
    }

    /// One running engine with the taps that feed it.
    private struct EngineSlot {
        let setup: EngineSetup
        let router: TapRouter
        let engine: UnisonEngine
    }

    private(set) var outputs: [AudioDevice] = []
    private(set) var defaultOutputID: AudioObjectID?
    /// Each output's own volume and mute, where it has them, read once a second so the
    /// sliders follow the volume keys and Control Center.
    private(set) var hardwareVolumes: [AudioObjectID: Float] = [:]
    private(set) var hardwareMutes: [AudioObjectID: Bool] = [:]
    /// Every app with an audio connection, playing or not.
    private(set) var apps: [AudioApp] = []
    private(set) var calibration: CalibrationProgress?
    /// The last thing that went wrong, shown until the next action succeeds.
    private(set) var problem: String?
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    /// When Keep in Sync last listened, and what it found.
    private(set) var lastSyncCheck: (date: Date, result: SyncChecker.Result)?
    var showsHiddenOutputs = false
    var showsHiddenApps = false
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
    /// Apps that have played long enough to be listed. Observed, unlike `lastHeard`, and
    /// changing only when an app first qualifies, so the row appears right away.
    private var heardApps: Set<String> = []
    /// When each app started its current stretch of playing.
    @ObservationIgnored private var playingSince: [String: Date] = [:]
    /// How long an app has to play before it gets a row, so a dictation chime or a
    /// notification doesn't add one.
    private static let playingToBeListed: TimeInterval = 2

    @ObservationIgnored private var slots: [Destination: EngineSlot] = [:]
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?
    @ObservationIgnored private var syncCheckTask: Task<Void, Never>?
    /// How often Keep in Sync listens while music plays.
    private static let syncCheckInterval: Duration = .seconds(10 * 60)
    @ObservationIgnored private var appWatchTask: Task<Void, Never>?
    /// Apps resting at full volume, waiting to be handed back to macOS untouched.
    @ObservationIgnored private var releaseTasks: [String: Task<Void, Never>] = [:]
    /// How long an app has to sit at 100% before Kodo stops capturing it. Long enough that
    /// dragging around full volume doesn't keep tapping and untapping the app.
    private static let releaseDelay: Duration = .seconds(2)
    /// Saved measurements whose runs disagreed by more than this are dropped at launch.
    private static let trustedSpread = 0.005
    @ObservationIgnored private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private let isPreview: Bool

    init() {
        isPreview = false
        outputs = AudioDevice.all().filter(\.isOutput)
        // Fine-tunes from before results had to agree may hold runs that disagreed wildly;
        // the approximate alignment is safer than those.
        for index in settings.groups.indices {
            settings.groups[index].measurements = settings.groups[index].measurements.filter { $0.value.spread <= Self.trustedSpread }
        }
        // An app left at full volume needs nothing from Kodo; don't capture it at launch.
        settings.appVolumes = settings.appVolumes.filter { id, volume in
            !Self.isFullVolume(volume) || settings.mutedApps.contains(id) || settings.appRoutes[id] != nil
        }
        refreshDefaultOutput()
        refreshApps()
        listenForDeviceChanges()
        watchApps()
        reconcileEngines()
        scheduleSyncChecks()
    }

    /// Fixed sample data for designing the menu without touching any audio.
    init(previewOutputs: [AudioDevice], apps: [AudioApp], settings: KodoSettings, isSyncOn: Bool, defaultOutputID: AudioObjectID?) {
        isPreview = true
        outputs = previewOutputs
        self.apps = apps
        var settings = settings
        settings.syncEnabled = isSyncOn
        self.settings = settings
        self.defaultOutputID = defaultOutputID
        hardwareVolumes = Dictionary(uniqueKeysWithValues: previewOutputs.map { ($0.id, Float(0.6)) })
        hardwareMutes = Dictionary(uniqueKeysWithValues: previewOutputs.map { ($0.id, false) })
        lastHeard = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Date.now) })
        heardApps = Set(apps.map(\.id))
    }

    // MARK: - State for the menu

    var group: SpeakerGroup {
        settings.activeGroup
    }

    var groups: [SpeakerGroup] {
        settings.groups
    }

    /// On while you want it and the group has a speaker connected, or no speakers yet, so you
    /// can pick them. When a group's speakers all leave it pauses, and it picks up again as
    /// soon as one reconnects.
    var isSyncOn: Bool {
        settings.syncEnabled && (!activeOutputs.isEmpty || group.outputs.isEmpty)
    }

    /// Sync is wanted but every speaker in the group is away.
    var isSyncPaused: Bool {
        settings.syncEnabled && !isSyncOn
    }

    /// Sync with speakers to play through, which is when the engine plays the group.
    private var isSyncPlaying: Bool {
        isSyncOn && !activeOutputs.isEmpty
    }

    var isCalibrating: Bool {
        calibration != nil
    }

    /// Outputs to list: everything connected, minus the ones you hid.
    var listedOutputs: [AudioDevice] {
        outputs.filter { showsHiddenOutputs || !isHidden($0) }
    }

    /// Outputs an app can be sent to.
    var routableOutputs: [AudioDevice] {
        outputs.filter { !isHidden($0) }
    }

    var hiddenOutputCount: Int {
        outputs.filter(isHidden).count
    }

    /// The group's speakers that are connected right now, in the order Core Audio lists them.
    var activeOutputs: [AudioDevice] {
        outputs.filter { group.outputs.contains($0.uid) && !isHidden($0) }
    }

    var needsCalibration: Bool {
        activeOutputs.count > 1 && activeOutputs.contains { group.measurements[$0.uid] == nil }
    }

    /// Apps worth a row: playing for more than a moment, played in the last few minutes, or
    /// adjusted. Hidden apps only while you ask to see them.
    var visibleApps: [AudioApp] {
        let cutoff = Date.now.addingTimeInterval(-Self.pausedAppLinger)
        return apps.filter { app in
            guard showsHiddenApps || !isHidden(app) else {
                return false
            }
            return isAdjusted(app) || (heardApps.contains(app.id) && (lastHeard[app.id] ?? .distantPast) > cutoff)
        }
            .sorted { lhs, rhs in
                lhs.isPlaying != rhs.isPlaying ? lhs.isPlaying : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// The menu bar drum: solid while Sync plays, outlined otherwise, slashed when muted.
    var menuBarStyle: MenuBarIcon.Style {
        if isSyncPlaying {
            return activeOutputs.allSatisfy(isMuted) ? .muted : .filled
        }
        let output = outputs.first { $0.id == defaultOutputID }
        return output.map(isMuted) == true ? .muted : .outlined
    }

    /// Whether a speaker is lit: part of the group with Sync on, the Mac's output with it off.
    func isActive(_ output: AudioDevice) -> Bool {
        isSyncOn ? isSelected(output) : output.id == defaultOutputID
    }

    func isSelected(_ output: AudioDevice) -> Bool {
        group.outputs.contains(output.uid)
    }

    func isHidden(_ output: AudioDevice) -> Bool {
        settings.hiddenOutputs.contains(output.uid)
    }

    func measurement(for output: AudioDevice) -> Measurement? {
        group.measurements[output.uid]
    }

    func delay(for output: AudioDevice) -> Double? {
        currentDelays()[output.uid]
    }

    func trim(for output: AudioDevice) -> Double {
        group.trims[output.uid] ?? 0
    }

    /// The slider value for a speaker row: the speaker's own volume, like Control Center,
    /// so it's never a second volume stacked on one you can't see. Only a speaker without a
    /// volume of its own uses Kodo's level, and only in Sync. Nil when the row has no slider.
    func volume(for output: AudioDevice) -> Float? {
        guard isSyncOn || output.id == defaultOutputID else {
            return nil
        }
        if let volume = hardwareVolumes[output.id] {
            return volume
        }
        return isSyncOn ? group.volumes[output.uid] ?? 1 : nil
    }

    func isMuted(_ output: AudioDevice) -> Bool {
        if let muted = hardwareMutes[output.id] {
            return muted
        }
        return isSyncOn && group.mutedOutputs.contains(output.uid)
    }

    /// The app's gain: 0 to 1, or up to 2 when boosted.
    func volume(for app: AudioApp) -> Float {
        settings.appVolumes[app.id] ?? 1
    }

    func isMuted(_ app: AudioApp) -> Bool {
        settings.mutedApps.contains(app.id)
    }

    func isHidden(_ app: AudioApp) -> Bool {
        settings.hiddenApps.contains(app.id)
    }

    var hiddenAppCount: Int {
        apps.filter(isHidden).count
    }

    func isBoosted(_ app: AudioApp) -> Bool {
        settings.boostedApps.contains(app.id)
    }

    /// The speaker an app was sent to, if it's connected.
    func route(for app: AudioApp) -> AudioDevice? {
        guard let uid = settings.appRoutes[app.id] else {
            return nil
        }
        return routableOutputs.first { $0.uid == uid }
    }

    // MARK: - Group actions

    func selectGroup(_ id: SpeakerGroup.ID) {
        guard settings.groups.contains(where: { $0.id == id }) else {
            return
        }
        problem = nil
        settings.activeGroupID = id
        reconcileEngines()
    }

    /// Starts an empty group and switches to it, so you can pick its speakers right away.
    func addGroup() {
        let taken = Set(settings.groups.map(\.name))
        let name = (2...).lazy.map { "Group \($0)" }.first { !taken.contains($0) } ?? "New Group"
        let group = SpeakerGroup(name: name)
        settings.groups.append(group)
        selectGroup(group.id)
    }

    func renameGroup(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        settings.activeGroup.name = trimmed
    }

    func deleteGroup() {
        guard settings.groups.count > 1 else {
            return
        }
        settings.groups.removeAll { $0.id == settings.activeGroupID }
        selectGroup(settings.groups[0].id)
    }

    // MARK: - Speaker actions

    func setSyncOn(_ on: Bool) {
        problem = nil
        settings.syncEnabled = on
        reconcileEngines()
    }

    /// With Sync on, adds or removes the speaker from the group. With it off, plays through it.
    func choose(_ output: AudioDevice) {
        problem = nil
        if isSyncOn {
            if settings.activeGroup.outputs.remove(output.uid) == nil {
                settings.activeGroup.outputs.insert(output.uid)
            }
            reconcileEngines()
            return
        }
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

    func setVolume(_ volume: Float, for output: AudioDevice) {
        guard hardwareVolumes[output.id] != nil else {
            settings.activeGroup.volumes[output.uid] = volume
            settings.activeGroup.mutedOutputs.remove(output.uid)
            return
        }
        // Reaching for the slider means you want to hear it.
        if hardwareMutes[output.id] == true {
            setHardwareMute(false, for: output)
        }
        hardwareVolumes[output.id] = volume
        if !isPreview {
            output.setHardwareVolume(volume)
        }
    }

    func toggleMute(_ output: AudioDevice) {
        guard let muted = hardwareMutes[output.id] else {
            if settings.activeGroup.mutedOutputs.remove(output.uid) == nil {
                settings.activeGroup.mutedOutputs.insert(output.uid)
            }
            return
        }
        setHardwareMute(!muted, for: output)
    }

    private func setHardwareMute(_ muted: Bool, for output: AudioDevice) {
        hardwareMutes[output.id] = muted
        if !isPreview {
            output.setHardwareMute(muted)
        }
    }

    func nudge(_ output: AudioDevice, by seconds: Double) {
        let trim = (group.trims[output.uid] ?? 0) + seconds
        settings.activeGroup.trims[output.uid] = abs(trim) < 0.0005 ? nil : trim
    }

    func resetTrim(for output: AudioDevice) {
        settings.activeGroup.trims[output.uid] = nil
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
        reconcileEngines()
    }

    func setSampleRate(_ rate: Double, for output: AudioDevice) {
        do {
            try output.setNominalSampleRate(rate)
        } catch {
            problem = "\(output.name) can't switch to that sample rate right now."
        }
        // Engines settled on a shared rate when they started; let them settle again.
        for (destination, slot) in slots where slot.engine.outputs.contains(output) {
            slots[destination] = nil
        }
        reconcileEngines()
    }

    // MARK: - App actions

    /// Takes the slider's position, 0 to 1, which covers twice the range for a boosted app.
    func setSliderValue(_ position: Double, for app: AudioApp) {
        let gain = Float(position) * (isBoosted(app) ? 2 : 1)
        settings.appVolumes[app.id] = gain
        // Reaching for the slider means you want to hear it.
        settings.mutedApps.remove(app.id)
        reconcileEngines()
        scheduleRelease(of: app)
    }

    func sliderValue(for app: AudioApp) -> Double {
        Double(volume(for: app)) / (isBoosted(app) ? 2 : 1)
    }

    func toggleMute(_ app: AudioApp) {
        if settings.mutedApps.remove(app.id) == nil {
            settings.mutedApps.insert(app.id)
        }
        reconcileEngines()
        scheduleRelease(of: app)
    }

    func setBoosted(_ boosted: Bool, for app: AudioApp) {
        if boosted {
            settings.boostedApps.insert(app.id)
        } else {
            settings.boostedApps.remove(app.id)
            if volume(for: app) > 1 {
                settings.appVolumes[app.id] = 1
                scheduleRelease(of: app)
            }
        }
    }

    /// Sends an app to one speaker, or back to wherever Kodo plays with `nil`.
    func setRoute(_ output: AudioDevice?, for app: AudioApp) {
        settings.appRoutes[app.id] = output?.uid
        reconcileEngines()
        scheduleRelease(of: app)
    }

    /// Hides an app from the menu and puts it back to normal, so Kodo leaves it alone.
    func setHidden(_ hidden: Bool, for app: AudioApp) {
        if hidden {
            settings.hiddenApps.insert(app.id)
            reset(app)
        } else {
            settings.hiddenApps.remove(app.id)
        }
        if hiddenAppCount == 0 {
            showsHiddenApps = false
        }
    }

    /// Puts the app back to normal: full volume, unmuted, played wherever Kodo plays.
    func reset(_ app: AudioApp) {
        settings.appVolumes[app.id] = nil
        settings.mutedApps.remove(app.id)
        settings.boostedApps.remove(app.id)
        settings.appRoutes[app.id] = nil
        reconcileEngines()
    }

    private static func isFullVolume(_ volume: Float) -> Bool {
        abs(volume - 1) < 0.005
    }

    /// Once an app has rested at 100%, unmuted and unrouted for a moment, stops capturing
    /// it, so Kodo only records system audio while something actually needs it.
    private func scheduleRelease(of app: AudioApp) {
        releaseTasks[app.id]?.cancel()
        guard needsNothing(app) else {
            releaseTasks[app.id] = nil
            return
        }
        releaseTasks[app.id] = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseDelay)
            guard let self, !Task.isCancelled, needsNothing(app) else {
                return
            }
            releaseTasks[app.id] = nil
            settings.appVolumes[app.id] = nil
            reconcileEngines()
        }
    }

    private func needsNothing(_ app: AudioApp) -> Bool {
        Self.isFullVolume(volume(for: app)) && !isMuted(app) && settings.appRoutes[app.id] == nil
    }

    // MARK: - Calibration

    func calibrate() {
        guard !isCalibrating, isSyncPlaying else {
            return
        }
        problem = nil
        calibrationTask = Task { await runCalibration() }
    }

    func cancelCalibration() {
        calibrationTask?.cancel()
    }

    /// Turns on listening to the music now and then, asking for the microphone first.
    func setKeepsInSync(_ on: Bool) {
        problem = nil
        guard on else {
            settings.keepsInSync = false
            scheduleSyncChecks()
            return
        }
        Task {
            guard await microphoneAllowed() else {
                problem = "Keep in Sync needs the microphone. Allow it in System Settings → Privacy & Security → Microphone."
                return
            }
            settings.keepsInSync = true
            scheduleSyncChecks()
        }
    }

    /// Whether a check can run now: a fine-tuned group playing, with music to listen to.
    private var canCheckSync: Bool {
        settings.keepsInSync && isSyncPlaying && activeOutputs.count > 1 && !needsCalibration
            && !isCalibrating && apps.contains(where: \.isPlaying)
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func scheduleSyncChecks() {
        syncCheckTask?.cancel()
        guard settings.keepsInSync, !isPreview else {
            return
        }
        syncCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncCheckInterval)
                guard let self, !Task.isCancelled else {
                    return
                }
                if canCheckSync {
                    await checkSync()
                }
            }
        }
    }

    private func checkSync() async {
        guard let slot = slots[.kodo], slot.setup.capturesEverything, let microphone = AudioDevice.calibrationMicrophone() else {
            return
        }
        let groupID = group.id
        let checker = SyncChecker(engine: slot.engine, microphone: microphone, outputs: activeOutputs) { [weak self] output in
            self?.applyMix(moving: output)
        }
        do {
            let result = try await checker.check()
            guard group.id == groupID else {
                return
            }
            if case .corrected(let corrections) = result {
                settings.activeGroup.drifts.merge(corrections) { $0 + $1 }
            }
            lastSyncCheck = (.now, result)
        } catch {
            // A missed check is harmless; the next one tries again.
        }
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

    // MARK: - Engines

    /// Where an app plays right now. A route to a speaker that's away falls back to Kodo.
    private func destination(for app: AudioApp) -> Destination {
        route(for: app).map { .device(uid: $0.uid) } ?? .kodo
    }

    private func apps(for destination: Destination) -> [AudioApp] {
        adjustedApps().filter { self.destination(for: $0) == destination }
    }

    /// Every engine that has to run, and what it has to play.
    private var neededSetups: [Destination: EngineSetup] {
        var setups: [Destination: EngineSetup] = [:]
        if isSyncPlaying {
            setups[.kodo] = EngineSetup(outputs: activeOutputs.map(\.id), capturesEverything: true)
        } else if !apps(for: .kodo).isEmpty, let defaultOutputID, outputs.contains(where: { $0.id == defaultOutputID }) {
            setups[.kodo] = EngineSetup(outputs: [defaultOutputID], capturesEverything: false)
        }
        for output in routableOutputs where !apps(for: .device(uid: output.uid)).isEmpty {
            setups[.device(uid: output.uid)] = EngineSetup(outputs: [output.id], capturesEverything: false)
        }
        return setups
    }

    /// Starts, stops, or rebuilds each engine to match what's needed, then routes the apps.
    private func reconcileEngines() {
        guard !isPreview else {
            return
        }
        let needed = neededSetups
        for (destination, slot) in slots where needed[destination] != slot.setup {
            if destination == .kodo {
                calibrationTask?.cancel()
            }
            slots[destination] = nil
        }
        for (destination, setup) in needed where slots[destination] == nil {
            do {
                let router = try TapRouter(capturesEverything: setup.capturesEverything)
                _ = try router.route(apps(for: destination), excluding: processesCaptured(outsideOf: destination))
                let engine = try UnisonEngine(outputs: setup.outputs.compactMap { id in outputs.first { $0.id == id } }, taps: router.taps)
                slots[destination] = EngineSlot(setup: setup, router: router, engine: engine)
                try engine.start()
            } catch {
                slots[destination] = nil
                if destination == .kodo, setup.capturesEverything {
                    settings.syncEnabled = false
                }
                problem = error.localizedDescription
            }
        }
        routeApps()
        applyMix()
    }

    /// Processes that engines other than this one capture, so a global tap leaves them out.
    private func processesCaptured(outsideOf destination: Destination) -> [AudioObjectID] {
        adjustedApps().filter { self.destination(for: $0) != destination }.flatMap(\.processes)
    }

    private func currentDelays() -> [String: Double] {
        let active = activeOutputs
        let latencies = Dictionary(uniqueKeysWithValues: active.compactMap { output in
            group.measurements[output.uid].map { (output.uid, $0.latency) }
        })
        let corrections = group.trims.merging(group.drifts) { $0 + $1 }
        var delays = AlignmentPlan.delays(latencies: latencies, trims: corrections)
        // Outputs nobody has measured yet still honour a manual nudge.
        for output in active where delays[output.uid] == nil {
            delays[output.uid] = max(corrections[output.uid] ?? 0, 0)
        }
        return delays
    }

    /// Applies every engine's delays and volumes. Keep in Sync moves one speaker a little
    /// later while it listens, to tell that speaker's arrival apart from the others.
    private func applyMix(moving movedOutput: AudioDevice? = nil) {
        for (destination, slot) in slots {
            if destination == .kodo, slot.setup.capturesEverything {
                // Kodo's own level only for speakers that have no volume of their own; the
                // others play at full level and their own volume does the rest.
                var gains: [String: Float] = [:]
                for output in activeOutputs where hardwareVolumes[output.id] == nil {
                    gains[output.uid] = group.mutedOutputs.contains(output.uid) ? 0 : group.volumes[output.uid] ?? 1
                }
                var delays = currentDelays()
                if let movedOutput {
                    delays[movedOutput.uid, default: 0] += SyncChecker.shift
                }
                slot.engine.apply(delays: delays, gains: gains)
            } else {
                // A single output needs no delay, and its volume is the device's own.
                slot.engine.apply(delays: [:], gains: [:])
            }
        }
        applyAppGains()
    }

    // MARK: - Apps

    private func isAdjusted(_ app: AudioApp) -> Bool {
        settings.appVolumes[app.id] != nil || settings.mutedApps.contains(app.id) || route(for: app) != nil
    }

    private func adjustedApps() -> [AudioApp] {
        apps.filter(isAdjusted)
    }

    /// Gives each engine's apps their own taps, then sets every tap's gain.
    private func routeApps() {
        for (destination, slot) in slots {
            do {
                let retired = try slot.router.route(apps(for: destination), excluding: processesCaptured(outsideOf: destination))
                if let retired {
                    try withExtendedLifetime(retired) {
                        try slot.engine.setTaps(slot.router.taps)
                    }
                }
            } catch {
                problem = error.localizedDescription
            }
        }
        applyAppGains()
    }

    private func applyAppGains() {
        for slot in slots.values {
            if slot.router.capturesEverything {
                slot.engine.setGain(1, forInput: 0)
            }
        }
        for app in adjustedApps() {
            guard let slot = slots[destination(for: app)], let input = slot.router.input(for: app.id) else {
                continue
            }
            slot.engine.setGain(isMuted(app) ? 0 : volume(for: app), forInput: input)
        }
    }

    private func refreshApps() {
        let current = AudioAppCatalog.current()
        let now = Date.now
        for app in current {
            guard app.isPlaying else {
                playingSince[app.id] = nil
                continue
            }
            let since = playingSince[app.id] ?? now
            playingSince[app.id] = since
            if now.timeIntervalSince(since) >= Self.playingToBeListed {
                lastHeard[app.id] = now
                if !heardApps.contains(app.id) {
                    heardApps.insert(app.id)
                }
            }
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
                    reconcileEngines()
                }
                refreshHardwareLevels()
            }
        }
    }

    // MARK: - Calibration run

    private func runCalibration() async {
        guard await microphoneAllowed() else {
            problem = "Kodo needs the microphone to fine-tune. Allow it in System Settings → Privacy & Security → Microphone."
            return
        }
        guard let microphone = AudioDevice.calibrationMicrophone() else {
            problem = "There is no microphone to fine-tune with."
            return
        }
        guard let slot = slots[.kodo], slot.setup.capturesEverything else {
            return
        }

        let groupID = group.id
        let calibrator = Calibrator(engine: slot.engine, microphone: microphone)
        calibration = CalibrationProgress(output: "", fraction: 0)
        defer { calibration = nil }
        do {
            let outcome = try await calibrator.measure { [weak self] output, fraction in
                self?.calibration = CalibrationProgress(output: output.name, fraction: fraction)
            }
            guard group.id == groupID else {
                return
            }
            settings.activeGroup.measurements.merge(outcome.measurements) { $1 }
            // A speaker without a steady answer goes back to the approximate alignment rather
            // than keeping an old number that may be just as wrong.
            for uid in outcome.unsteady + outcome.unheard {
                settings.activeGroup.measurements[uid] = nil
            }
            // Fresh measurements start clean; old automatic corrections no longer apply.
            settings.activeGroup.drifts = [:]
            settings.activeGroup.calibratedAt = .now
            problem = calibrationProblem(outcome, outputs: slot.engine.outputs)
        } catch is CancellationError {
            // Stopped or rebuilt on purpose; nothing to report.
        } catch {
            problem = error.localizedDescription
        }
    }

    private func calibrationProblem(_ outcome: CalibrationOutcome, outputs: [AudioDevice]) -> String? {
        let names = { (uids: [String]) in outputs.filter { uids.contains($0.uid) }.map(\.name).formatted(.list(type: .and)) }
        if !outcome.unsteady.isEmpty {
            return "\(names(outcome.unsteady)) gave a different answer each time, so it stays roughly in step for now. Move it or the Mac a little closer and fine-tune again."
        }
        if !outcome.unheard.isEmpty {
            return "Couldn't hear \(names(outcome.unheard)). Turn it up or move it closer, then try again."
        }
        return nil
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

    /// A speaker that reconnects gets a new object ID, which changes the needed setups, so
    /// the group picks it up again with its saved volume and delay.
    private func devicesChanged() {
        let current = AudioDevice.all().filter(\.isOutput)
        if current != outputs {
            outputs = current
        }
        refreshDefaultOutput()
        reconcileEngines()
    }

    private func refreshDefaultOutput() {
        let id = AudioDevice.defaultOutputID
        if id != defaultOutputID {
            defaultOutputID = id
        }
        refreshHardwareLevels()
    }

    private func refreshHardwareLevels() {
        guard !isPreview else {
            return
        }
        var volumes: [AudioObjectID: Float] = [:]
        var mutes: [AudioObjectID: Bool] = [:]
        for output in outputs {
            volumes[output.id] = output.hardwareVolume
            mutes[output.id] = output.hardwareMute
        }
        if volumes != hardwareVolumes {
            hardwareVolumes = volumes
        }
        if mutes != hardwareMutes {
            hardwareMutes = mutes
        }
    }
}
