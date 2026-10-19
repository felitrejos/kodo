import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import KodoCore
import Observation
import ServiceManagement
import WidgetKit

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
        /// The device whose clock the others follow.
        var clockUID: String?
        var bufferFrames: UInt32?
    }

    /// What a device looked like when its engine was built. A Bluetooth speaker that changes
    /// its rate or channels mid-stream, as when it renegotiates its codec, can leave the
    /// engine sounding broken until it's rebuilt.
    private struct DeviceState: Equatable {
        var sampleRate: Double
        var outputChannels: [Int]
        var isAlive: Bool

        init(_ device: AudioDevice) {
            sampleRate = device.nominalSampleRate
            outputChannels = device.id.streamChannelCounts(scope: kAudioObjectPropertyScopeOutput)
            isAlive = ((try? device.id.read(kAudioDevicePropertyDeviceIsAlive, default: UInt32(1))) ?? 1) != 0
        }
    }

    /// A wireless group gets a roomier IO buffer: drift correction gets more slack, and the
    /// extra 12 ms is nothing next to Bluetooth's quarter of a second.
    private static let wirelessBufferFrames: UInt32 = 1024

    /// One running engine with the taps that feed it.
    private struct EngineSlot {
        let setup: EngineSetup
        let router: TapRouter
        let engine: UnisonEngine
    }

    private(set) var outputs: [AudioDevice] = []
    private(set) var defaultOutputID: AudioObjectID?
    /// Kodo's own entry in the Sound output list, while its driver is installed.
    private(set) var kodoOutput: AudioDevice?
    private(set) var kodoOutputStatus: KodoOutput.Status
    private(set) var isInstallingKodoOutput = false
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
            publishControlState()
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
    /// Watches on the devices engines play through, and how each looked when its engine
    /// started.
    @ObservationIgnored private var deviceWatches: [AudioObjectID: (state: DeviceState, block: AudioObjectPropertyListenerBlock)] = [:]
    @ObservationIgnored private var deviceCheckTask: Task<Void, Never>?
    @ObservationIgnored private var reportedLatencies: [AudioObjectID: Double] = [:]
    /// Each group speaker's volume as a share of the Mac output's, so the volume keys can move
    /// the whole group without changing its balance.
    @ObservationIgnored private var groupBalance: [AudioObjectID: Float] = [:]
    /// The Mac output's last known volume and mute, to tell the volume keys apart from
    /// Kodo's own changes.
    @ObservationIgnored private var followedVolume: Float?
    @ObservationIgnored private var followedMute: Bool?
    /// Listens to the Mac output's volume and mute, so the group follows the keys at once.
    @ObservationIgnored private var outputLevelListener: (device: AudioObjectID, block: AudioObjectPropertyListenerBlock)?
    /// When Kodo last set each speaker's volume. A Bluetooth speaker reports a fast drag back
    /// late, as much as 0.6 s behind and in its own steps, so for a while after a write its
    /// readings are echoes, not news.
    @ObservationIgnored private var volumeWrites: [AudioObjectID: ContinuousClock.Instant] = [:]
    private static let volumeSettleTime: Duration = .milliseconds(1500)
    /// Takes the Mac output's settled level as the new balance once Kodo's writes stop echoing.
    @ObservationIgnored private var outputLevelSettleTask: Task<Void, Never>?
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var publishedControlState: SyncControlState?

    init() {
        isPreview = false
        outputs = AudioDevice.all().filter(\.isOutput)
        kodoOutput = KodoOutput.device()
        kodoOutputStatus = KodoOutput.status
        // Fine-tunes from before results had to agree may hold runs that disagreed wildly;
        // the approximate alignment is safer than those.
        for index in settings.groups.indices {
            settings.groups[index].measurements = settings.groups[index].measurements.filter { $0.value.spread <= Self.trustedSpread }
        }
        // An app left at full volume needs nothing from Kodo; don't capture it at launch.
        settings.appVolumes = settings.appVolumes.filter { id, volume in
            !Self.isFullVolume(volume) || settings.mutedApps.contains(id) || settings.appRoutes[id] != nil
        }
        // Just added to the Sound list: that's a wish to play through it.
        if UserDefaults.standard.bool(forKey: Self.selectsKodoOutputKey) {
            UserDefaults.standard.removeObject(forKey: Self.selectsKodoOutputKey)
            settings.syncEnabled = settings.syncEnabled || kodoOutput != nil
        }
        // Sync was on when Kodo last quit, and quitting handed the Mac back to a speaker.
        if settings.syncEnabled, let kodoOutput, AudioDevice.defaultOutputID != kodoOutput.id {
            if let current = outputs.first(where: { $0.id == AudioDevice.defaultOutputID }) {
                settings.lastOutputUID = current.uid
            }
            try? kodoOutput.makeDefaultOutput()
        }
        refreshDefaultOutput()
        refreshApps()
        listenForDeviceChanges()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.leaveKodoOutput()
                // Nothing plays once Kodo quits; Sync picks up again at the next launch.
                self?.publishControlState(isOn: false)
            }
        }
        watchApps()
        reconcileEngines()
        rememberBalance()
        scheduleSyncChecks()
        publishControlState()
    }

    /// Fixed sample data for designing the menu without touching any audio.
    init(previewOutputs: [AudioDevice], apps: [AudioApp], settings: KodoSettings, isSyncOn: Bool, defaultOutputID: AudioObjectID?, kodoOutputStatus: KodoOutput.Status = .unavailable) {
        isPreview = true
        self.kodoOutputStatus = kodoOutputStatus
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
        activeOutputs.count > 1 && activeOutputs.contains { measurements[$0.uid] == nil }
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

    /// The speaker the group follows: its clock drives the others. Kodo picks the wireless
    /// speaker with the most delay, usually the one the rest already wait for, because a
    /// Bluetooth link is the part most likely to crackle when its audio is resampled; wired
    /// speakers take resampling in stride. Fine-tune then lines the rest up with it.
    var leadSpeaker: AudioDevice? {
        let active = activeOutputs
        let wireless = active.filter { $0.transport == .bluetooth || $0.transport == .airPlay }
        if let slowest = wireless.max(by: { reportedLatency(of: $0) < reportedLatency(of: $1) }) {
            return slowest
        }
        return active.first { $0.transport == .builtIn } ?? active.first
    }

    /// The group's fine-tune results, if they were measured with today's lead.
    private var measurements: [String: Measurement] {
        group.measuredLeadUID == leadSpeaker?.uid ? group.measurements : [:]
    }

    private func reportedLatency(of output: AudioDevice) -> Double {
        if let latency = reportedLatencies[output.id] {
            return latency
        }
        let latency = DeviceDetails(device: output).reportedLatency ?? 0
        reportedLatencies[output.id] = latency
        return latency
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
        measurements[output.uid]
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
        rememberBalance()
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
        // With Kodo in the Sound list, Sync on means the Mac plays to Kodo.
        if on, let kodoOutput {
            if let current = outputs.first(where: { $0.id == defaultOutputID }) {
                settings.lastOutputUID = current.uid
            }
            makeDefault(kodoOutput)
        } else if !on {
            leaveKodoOutput()
        }
        reconcileEngines()
        rememberBalance()
    }

    // MARK: - Kodo in the Sound list

    enum SoundMenuOffer {
        case add, update
    }

    /// What to offer about the Sound list, once each: adding Kodo the first time you use
    /// Speaker Sync, and updating it when this copy of Kodo carries a newer driver.
    var soundMenuOffer: SoundMenuOffer? {
        switch kodoOutputStatus {
        case .notInstalled:
            settings.syncEnabled && !settings.declinedSoundMenu ? .add : nil
        case .outdated:
            settings.skippedDriverVersion != KodoOutput.bundledVersion ? .update : nil
        case .installed, .unavailable:
            nil
        }
    }

    func declineSoundMenuOffer() {
        switch soundMenuOffer {
        case .add:
            settings.declinedSoundMenu = true
        case .update:
            settings.skippedDriverVersion = KodoOutput.bundledVersion
        case nil:
            break
        }
    }

    /// Set across the restart that follows adding Kodo to the Sound list.
    nonisolated private static let selectsKodoOutputKey = "selectsKodoOutputAtLaunch"

    func installKodoOutput() {
        runKodoOutputChange {
            try await KodoOutput.install()
            UserDefaults.standard.set(true, forKey: Self.selectsKodoOutputKey)
        }
    }

    func removeKodoOutput() {
        // You took it out on purpose, so don't offer it again; More can still add it.
        settings.declinedSoundMenu = true
        leaveKodoOutput()
        runKodoOutputChange(KodoOutput.uninstall)
    }

    private func runKodoOutputChange(_ change: @escaping @Sendable () async throws -> Void) {
        guard !isInstallingKodoOutput else {
            return
        }
        problem = nil
        isInstallingKodoOutput = true
        Task {
            defer {
                isInstallingKodoOutput = false
                kodoOutputStatus = KodoOutput.status
            }
            do {
                try await change()
                KodoOutput.relaunch()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Hands the Mac back to a real speaker if it's playing to Kodo, so it isn't left silent:
    /// the one it played through before, else the group's lead, else the built-in speakers.
    private func leaveKodoOutput() {
        guard let kodoOutput, AudioDevice.defaultOutputID == kodoOutput.id else {
            return
        }
        let target = outputs.first { $0.uid == settings.lastOutputUID }
            ?? leadSpeaker
            ?? outputs.first { $0.transport == .builtIn }
            ?? outputs.first
        if let target {
            makeDefault(target)
        }
    }

    private func makeDefault(_ output: AudioDevice) {
        do {
            try output.makeDefaultOutput()
            defaultOutputID = output.id
            listenToOutputLevel()
        } catch {
            problem = "Couldn't switch to \(output.name)."
        }
    }

    /// Tells the Speaker Sync control in Control Center whether Sync is on, and for which group.
    private func publishControlState(isOn: Bool? = nil) {
        guard !isPreview else {
            return
        }
        let state = SyncControlState(isOn: isOn ?? settings.syncEnabled, groupName: group.name)
        guard state != publishedControlState else {
            return
        }
        publishedControlState = state
        state.write()
        ControlCenter.shared.reloadControls(ofKind: SyncControlState.kind)
    }

    /// Apps playing to Kodo run at its rate; matching the lead's spares their audio a
    /// conversion on the way to the group.
    private func matchKodoOutputRate() {
        guard let kodoOutput, let rate = leadSpeaker?.nominalSampleRate, kodoOutput.supports(sampleRate: rate) else {
            return
        }
        try? kodoOutput.setNominalSampleRate(rate)
    }

    /// Picking Kodo in the Sound list turns Sync on; picking any other output turns it off.
    private func defaultOutputMoved() {
        // Restarting Core Audio for the driver moves the Mac's output by itself.
        guard !isInstallingKodoOutput, let kodoOutput, let defaultOutputID else {
            return
        }
        if defaultOutputID == kodoOutput.id {
            if !settings.syncEnabled {
                problem = nil
                settings.syncEnabled = true
            }
        } else if let output = outputs.first(where: { $0.id == defaultOutputID }) {
            settings.lastOutputUID = output.uid
            settings.syncEnabled = false
        }
    }

    /// With Sync on, adds or removes the speaker from the group. With it off, plays through it.
    func choose(_ output: AudioDevice) {
        problem = nil
        if isSyncOn {
            if settings.activeGroup.outputs.remove(output.uid) == nil {
                settings.activeGroup.outputs.insert(output.uid)
            }
            reconcileEngines()
            rememberBalance()
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
        writeVolume(volume, to: output)
        if output.id == defaultOutputID {
            settleOutputLevel()
        }
        // Moving one speaker on purpose sets a new balance for the volume keys to keep.
        rememberBalance()
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
        if output.id == defaultOutputID {
            followedMute = muted
        }
    }

    // MARK: - Volume keys

    /// The device the Mac plays to, Kodo's own output included.
    private var defaultOutput: AudioDevice? {
        guard let defaultOutputID else {
            return nil
        }
        return kodoOutput?.id == defaultOutputID ? kodoOutput : outputs.first { $0.id == defaultOutputID }
    }

    /// Notes how loud each group speaker is next to the Mac's output, the balance the volume
    /// keys keep. Called after anything that changes it on purpose.
    private func rememberBalance() {
        guard let defaultOutputID else {
            return
        }
        followedVolume = hardwareVolumes[defaultOutputID]
        followedMute = hardwareMutes[defaultOutputID]
        guard let level = followedVolume, level > 0.001 else {
            return
        }
        groupBalance = Dictionary(uniqueKeysWithValues: activeOutputs.compactMap { output in
            hardwareVolumes[output.id].map { (output.id, $0 / level) }
        })
    }

    /// The volume keys and Control Center change only the Mac's output. While Sync plays,
    /// Kodo carries the same change over to every other speaker in the group, keeping their
    /// balance, so the keys turn the whole group up and down.
    private func followOutputLevel() {
        guard !isPreview, outputLevelSettleTask == nil, let output = defaultOutput, !isSettling(output.id) else {
            return
        }
        let defaultOutputID = output.id
        let volume = output.hardwareVolume
        let muted = output.hardwareMute
        defer {
            followedVolume = volume
            followedMute = muted
        }
        guard isSyncPlaying, let volume, let previous = followedVolume else {
            return
        }
        let others = activeOutputs.filter { $0.id != defaultOutputID }

        if let muted, let wasMuted = followedMute, muted != wasMuted {
            for other in others where hardwareMutes[other.id] != nil {
                setHardwareMute(muted, for: other)
            }
        }
        guard abs(volume - previous) > 0.001 else {
            return
        }
        for other in others {
            guard let current = hardwareVolumes[other.id] else {
                continue
            }
            // A speaker joined since the balance was noted: take its share from right now.
            let share = groupBalance[other.id] ?? (previous > 0.001 ? current / previous : 1)
            groupBalance[other.id] = share
            writeVolume(min(max(share * volume, 0), 1), to: other)
        }
        hardwareVolumes[defaultOutputID] = volume
    }

    private func writeVolume(_ volume: Float, to output: AudioDevice) {
        hardwareVolumes[output.id] = volume
        guard !isPreview else {
            return
        }
        output.setHardwareVolume(volume)
        volumeWrites[output.id] = .now
    }

    /// Whether a speaker may still be echoing Kodo's last volume change back.
    private func isSettling(_ id: AudioObjectID) -> Bool {
        volumeWrites[id].map { ContinuousClock.now - $0 < Self.volumeSettleTime } ?? false
    }

    /// Ignores the Mac output's volume changes until Kodo's own writes stop echoing back, then
    /// takes the level the speaker settled on as the new balance, never as a key press.
    private func settleOutputLevel() {
        outputLevelSettleTask?.cancel()
        outputLevelSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.volumeSettleTime)
            guard !Task.isCancelled, let self else {
                return
            }
            outputLevelSettleTask = nil
            if let output = defaultOutput, let settled = output.hardwareVolume {
                hardwareVolumes[output.id] = settled
            }
            rememberBalance()
        }
    }

    /// Watches the Mac output's own volume and mute, moving the watch when the output changes.
    private func listenToOutputLevel() {
        guard !isPreview, outputLevelListener?.device != defaultOutputID else {
            return
        }
        let selectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]
        if let previous = outputLevelListener {
            for selector in selectors {
                var address = AudioObjectID.address(selector, scope: kAudioObjectPropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(previous.device, &address, .main, previous.block)
            }
            outputLevelListener = nil
        }
        guard let device = defaultOutputID else {
            return
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.followOutputLevel()
            }
        }
        for selector in selectors {
            var address = AudioObjectID.address(selector, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        }
        outputLevelListener = (device, block)
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
            let active = activeOutputs
            let isWireless = active.contains { $0.transport == .bluetooth || $0.transport == .airPlay }
            setups[.kodo] = EngineSetup(
                outputs: active.map(\.id),
                capturesEverything: true,
                clockUID: leadSpeaker?.uid,
                bufferFrames: active.count > 1 && isWireless ? Self.wirelessBufferFrames : nil)
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
            if setup.capturesEverything {
                matchKodoOutputRate()
            }
            do {
                let router = try TapRouter(capturesEverything: setup.capturesEverything)
                _ = try router.route(apps(for: destination), excluding: processesCaptured(outsideOf: destination))
                let engine = try UnisonEngine(
                    outputs: setup.outputs.compactMap { id in outputs.first { $0.id == id } },
                    taps: router.taps,
                    clockUID: setup.clockUID,
                    bufferFrames: setup.bufferFrames)
                slots[destination] = EngineSlot(setup: setup, router: router, engine: engine)
                try engine.start()
            } catch {
                slots[destination] = nil
                if destination == .kodo, setup.capturesEverything {
                    settings.syncEnabled = false
                    leaveKodoOutput()
                }
                problem = error.localizedDescription
            }
        }
        routeApps()
        applyMix()
        watchEngineDevices()
    }

    // MARK: - Keeping engines healthy

    /// Watches every device an engine plays through for changes that can break the stream.
    private func watchEngineDevices() {
        let inUse = Set(slots.values.flatMap { $0.engine.outputs })
        for (id, watch) in deviceWatches where !inUse.contains(where: { $0.id == id }) {
            for var address in Self.deviceWatchAddresses {
                AudioObjectRemovePropertyListenerBlock(id, &address, .main, watch.block)
            }
            deviceWatches[id] = nil
        }
        for device in inUse where deviceWatches[device.id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.deviceMayHaveChanged()
                }
            }
            for var address in Self.deviceWatchAddresses {
                AudioObjectAddPropertyListenerBlock(device.id, &address, .main, block)
            }
            deviceWatches[device.id] = (DeviceState(device), block)
        }
    }

    private static let deviceWatchAddresses = [
        AudioObjectID.address(kAudioDevicePropertyNominalSampleRate),
        AudioObjectID.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput),
        AudioObjectID.address(kAudioDevicePropertyDeviceIsAlive),
    ]

    /// Kodo's own sample rate changes set these off too, so wait for things to settle, then
    /// rebuild only the engines whose devices really look different from when they started.
    private func deviceMayHaveChanged() {
        deviceCheckTask?.cancel()
        deviceCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else {
                return
            }
            let changed = Set(deviceWatches.compactMap { id, watch in
                outputs.first { $0.id == id }.flatMap { DeviceState($0) == watch.state ? nil : id }
            })
            guard !changed.isEmpty else {
                return
            }
            for (destination, slot) in slots where slot.engine.outputs.contains(where: { changed.contains($0.id) }) {
                slots[destination] = nil
            }
            for id in changed {
                if let watch = deviceWatches[id] {
                    for var address in Self.deviceWatchAddresses {
                        AudioObjectRemovePropertyListenerBlock(id, &address, .main, watch.block)
                    }
                }
                deviceWatches[id] = nil
            }
            reconcileEngines()
        }
    }

    /// Processes that engines other than this one capture, so a global tap leaves them out.
    private func processesCaptured(outsideOf destination: Destination) -> [AudioObjectID] {
        adjustedApps().filter { self.destination(for: $0) != destination }.flatMap(\.processes)
    }

    private func currentDelays() -> [String: Double] {
        let active = activeOutputs
        let latencies = Dictionary(uniqueKeysWithValues: active.compactMap { output in
            measurements[output.uid].map { (output.uid, $0.latency) }
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
            // Measurements under another lead don't mix with these; start over.
            if group.measuredLeadUID != slot.engine.clockDevice.uid {
                settings.activeGroup.measurements = [:]
            }
            settings.activeGroup.measurements.merge(outcome.measurements) { $1 }
            settings.activeGroup.measuredLeadUID = slot.engine.clockDevice.uid
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
            reportedLatencies = [:]
        }
        let kodo = KodoOutput.device()
        if kodo != kodoOutput {
            kodoOutput = kodo
        }
        refreshDefaultOutput()
        reconcileEngines()
        rememberBalance()
    }

    private func refreshDefaultOutput() {
        let id = AudioDevice.defaultOutputID
        if id != defaultOutputID {
            defaultOutputID = id
            defaultOutputMoved()
        }
        refreshHardwareLevels()
        listenToOutputLevel()
    }

    private func refreshHardwareLevels() {
        guard !isPreview else {
            return
        }
        // In case the listener missed a key press.
        followOutputLevel()
        var volumes: [AudioObjectID: Float] = [:]
        var mutes: [AudioObjectID: Bool] = [:]
        for output in outputs + [kodoOutput].compactMap(\.self) {
            // Mid-drag a speaker still reports where the slider was a moment ago.
            volumes[output.id] = isSettling(output.id) ? hardwareVolumes[output.id] : output.hardwareVolume
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
