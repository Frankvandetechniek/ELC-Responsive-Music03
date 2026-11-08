import AppKit
import AVFoundation
import Combine
import CoreAudio
import ELCCore
import SwiftUI
import UniformTypeIdentifiers

enum AppMode: Equatable {
    case off
    case live
    case setlist
    case mood(String)

    var title: String {
        switch self {
        case .off: return "Off"
        case .live: return "Live input"
        case .setlist: return "Setlist"
        case .mood: return "Mood show"
        }
    }
}

struct AnalysisSettings: Codable, Equatable {
    var latencyCompensation: Double = 0.06   // live input
    var setlistLookahead: Double = 0.04       // file playback
    var minBPM: Double = 75
    var maxBPM: Double = 180
    var preferredBPM: Double = 124
}

/// Everything that is persisted between launches.
struct PersistedConfig: Codable {
    var rig: Rig = .elcDefault()
    var output = OutputSettings()
    var show = ShowSettings()
    var analysis = AnalysisSettings()
    var cid: [UInt8] = SACNPacketBuilder.randomCID()
    var inputDeviceName: String? = nil
    var setlist: [SetlistTrack] = []
    var autoAdvance: Bool = true
    /// Patch layout version: 2 = Flex L7 50ch (Extended 7) + Focus Hybrid 25ch.
    var rigVersion: Int? = PersistedConfig.currentRigVersion

    static let defaultsKey = "ELCResponsive.config.v1"
    static let currentRigVersion = 2

    static func load() -> PersistedConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var c = try? JSONDecoder().decode(PersistedConfig.self, from: data) else { return PersistedConfig() }
        if c.rigVersion != currentRigVersion {
            // Older patch (L7 16ch / Hybrid 19ch): move to the new channel modes and addresses,
            // keeping the universe and each fixture's calibration.
            var rig = Rig.elcDefault(universe: c.rig.fixtures.first?.universe ?? 1)
            for i in rig.fixtures.indices {
                if let old = c.rig.fixtures.first(where: { $0.id == rig.fixtures[i].id }) {
                    rig.fixtures[i].calibration = old.calibration
                }
            }
            c.rig = rig
            c.rigVersion = currentRigVersion
        }
        return c
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Configuration
    @Published var rig: Rig { didSet { rigChanged() } }
    @Published var output: OutputSettings { didSet { controller.update(settings: output); scheduleSave() } }
    @Published var show: ShowSettings { didSet { pushShowSettings(); scheduleSave() } }
    @Published var analysis: AnalysisSettings { didSet { analysisChanged(); scheduleSave() } }
    @Published var autoAdvance: Bool { didSet { scheduleSave() } }

    // State
    @Published private(set) var mode: AppMode = .off
    @Published var blackout = false { didSet { let b = blackout; controller.perform { $0.engine.blackout = b } } }
    @Published var holdLook = false { didSet { let h = holdLook; controller.perform { $0.engine.holdLook = h } } }
    /// Freeze the lighting show where it is.
    @Published var paused = false { didSet { let p = paused; controller.perform { $0.engine.paused = p } } }
    /// Default static look on/off.
    @Published var staticLook = false { didSet { let s = staticLook; controller.perform { $0.engine.staticLook = s } } }
    @Published private(set) var status = EngineStatus()
    @Published private(set) var fixtureStates: [Int: FixtureState] = [:]
    @Published private(set) var frames: [UInt16: [UInt8]] = [:]
    @Published private(set) var music = MusicState()
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputError: String?
    @Published private(set) var packetsSent: UInt64 = 0
    @Published var errorMessage: String?

    // Live input
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedInputID: AudioDeviceID? { didSet { if mode == .live { startLive() } } }
    @Published var tapTimes: [Double] = []
    @Published var manualBPM: Double? = nil

    // Setlist
    @Published var setlist: [SetlistTrack] { didSet { scheduleSave() } }
    @Published var currentTrackID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackTime: Double = 0
    @Published private(set) var playbackDuration: Double = 0
    @Published var analyzing: [UUID: Double] = [:]

    // Test / calibration
    @Published var testFixtureID: Int? = nil
    @Published var testPose: TestPose = .up { didSet { updateTest() } }

    enum TestPose: String, CaseIterable, Identifiable {
        case up = "Straight up"
        case forward45 = "Forward 45°"
        case left = "Lean left 45°"
        case right = "Lean right 45°"
        var id: String { rawValue }
    }

    let controller: OutputController
    private let liveInput = LiveInput()
    private let player = SetlistPlayer()
    private let sourceBox = Locked<AppMode>(.off)
    private var uiTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var cid: [UInt8]

    init() {
        let cfg = PersistedConfig.load()
        rig = cfg.rig
        output = cfg.output
        show = cfg.show
        analysis = cfg.analysis
        autoAdvance = cfg.autoAdvance
        setlist = cfg.setlist
        cid = cfg.cid
        controller = OutputController(rig: cfg.rig, settings: cfg.output, cid: cfg.cid)
        controller.engine.settings = cfg.show

        let live = liveInput
        let player = player
        let box = sourceBox
        controller.musicProvider = {
            switch box.get() {
            case .live: return live.analyzer?.state ?? MusicState()
            case .setlist: return player.musicState(now: OutputController.monotonicNow())
            default: return MusicState()
            }
        }
        player.lookahead = cfg.analysis.setlistLookahead
        player.onFinished = { [weak self] in self?.trackFinished() }

        refreshInputDevices()
        if let name = cfg.inputDeviceName, let dev = inputDevices.first(where: { $0.name == name }) {
            selectedInputID = dev.id
        } else {
            selectedInputID = LiveInput.defaultInputDevice()
        }
        controller.start()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUI() }
        }
        // Load cached analyses for the saved setlist.
        for i in setlist.indices { setlist[i].analysis = AnalysisCache.load(for: setlist[i].url) }
        for t in setlist where t.analysis == nil { analyze(trackID: t.id) }
    }

    func shutdown() {
        liveInput.stop()
        player.stop()
        controller.stop()
        save()
    }

    // MARK: - Mode

    func setMode(_ m: AppMode) {
        if m == mode { return }
        let old = mode
        mode = m
        if old == .live && m != .live { liveInput.stop() }
        switch m {
        case .off:
            sourceBox.set(.off)
            controller.perform { $0.engine.mode = .off }
        case .live:
            sourceBox.set(.live)
            startLive()
            controller.perform { $0.engine.mode = .audio }
        case .setlist:
            sourceBox.set(.setlist)
            controller.perform { $0.engine.mode = .audio }
        case .mood(let id):
            controller.perform { $0.engine.mode = .mood(id) }
        }
    }

    // MARK: - Live input

    func refreshInputDevices() {
        inputDevices = LiveInput.inputDevices()
    }

    func startLive() {
        let deviceID = selectedInputID
        let a = analysis
        let manual = manualBPM
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.errorMessage = "Microphone access was denied. Allow it in System Settings → Privacy & Security → Microphone."
                    return
                }
                do {
                    try self.liveInput.start(deviceID: deviceID) { la in
                        la.config.latencyCompensation = a.latencyCompensation
                        la.config.minBPM = a.minBPM
                        la.config.maxBPM = a.maxBPM
                        la.config.preferredBPM = a.preferredBPM
                        la.manualBPM = manual
                    }
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = "Audio input: \(error.localizedDescription)"
                }
            }
        }
        scheduleSave()
    }

    func tapTempo() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = tapTimes.last, now - last > 2 { tapTimes = [] }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst() }
        if tapTimes.count >= 4 {
            let span = tapTimes.last! - tapTimes.first!
            let bpm = 60 * Double(tapTimes.count - 1) / span
            setManualBPM(bpm)
        }
    }

    func setManualBPM(_ bpm: Double?) {
        manualBPM = bpm.map { (clamp($0, 40, 220) * 10).rounded() / 10 }
        liveInput.analyzer?.manualBPM = manualBPM
    }

    func markDownbeat() { liveInput.analyzer?.markDownbeat() }
    func nudge(_ beats: Double) { liveInput.analyzer?.nudge(beats) }

    // MARK: - Setlist

    func addTracks(urls: [URL]) {
        let allowed = Set(["wav", "mp3", "aif", "aiff", "m4a", "flac", "caf"])
        for url in urls where allowed.contains(url.pathExtension.lowercased()) {
            var t = SetlistTrack(path: url.path, title: url.deletingPathExtension().lastPathComponent)
            if let f = try? AVAudioFile(forReading: url) {
                t.duration = Double(f.length) / f.processingFormat.sampleRate
            }
            t.analysis = AnalysisCache.load(for: url)
            setlist.append(t)
            if t.analysis == nil { analyze(trackID: t.id) }
        }
    }

    func openAddDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.wav, .mp3, .aiff, .mpeg4Audio, .audio]
        if panel.runModal() == .OK { addTracks(urls: panel.urls) }
    }

    func removeTracks(at offsets: IndexSet) {
        let ids = offsets.map { setlist[$0].id }
        if let cur = currentTrackID, ids.contains(cur) { stopPlayback(); currentTrackID = nil }
        setlist.remove(atOffsets: offsets)
    }

    func moveTracks(from: IndexSet, to: Int) { setlist.move(fromOffsets: from, toOffset: to) }

    func analyze(trackID: UUID) {
        guard let track = setlist.first(where: { $0.id == trackID }), analyzing[trackID] == nil else { return }
        analyzing[trackID] = 0
        let url = track.url
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let (samples, sr) = try AudioDecoding.monoSamples(url: url)
                let base = TrackAnalyzer.analyze(samples: samples, sampleRate: sr) { p in
                    Task { @MainActor in self.analyzing[trackID] = p * 0.85 }
                }
                // Instrument / vocal recognition with Apple's on-device sound classifier.
                let evidence = FileSoundClassifier.evidence(url: url)
                Task { @MainActor in self.analyzing[trackID] = 0.92 }
                // Genre / mood tags from the MusiCNN neural network.
                let tags = GenreModel.tags(url: url)
                let result = (evidence.isEmpty && tags.isEmpty) ? base : base.withEvidence(evidence, tags: tags)
                AnalysisCache.save(result, for: url)
                await MainActor.run {
                    self.analyzing[trackID] = nil
                    if let i = self.setlist.firstIndex(where: { $0.id == trackID }) {
                        self.setlist[i].analysis = result
                        self.setlist[i].duration = result.duration
                    }
                    if self.currentTrackID == trackID { self.player.updateAnalysis(result) }
                }
            } catch {
                await MainActor.run {
                    self.analyzing[trackID] = nil
                    self.errorMessage = "Could not analyse \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    func play(trackID: UUID, from time: Double = 0) {
        guard let t = setlist.first(where: { $0.id == trackID }) else { return }
        if mode != .setlist { setMode(.setlist) }
        do {
            try player.load(track: t)
            currentTrackID = trackID
            try player.play(from: time)
        } catch {
            errorMessage = "Playback: \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        if player.isPlaying { player.pause(); return }
        if currentTrackID == nil, let first = setlist.first { play(trackID: first.id); return }
        if mode != .setlist { setMode(.setlist) }
        do { try player.play() } catch { errorMessage = "Playback: \(error.localizedDescription)" }
    }

    func stopPlayback() { player.stop() }

    func next() {
        guard let cur = currentTrackID, let i = setlist.firstIndex(where: { $0.id == cur }) else {
            if let f = setlist.first { play(trackID: f.id) }
            return
        }
        if i + 1 < setlist.count { play(trackID: setlist[i + 1].id) } else { player.stop() }
    }

    func previous() {
        guard let cur = currentTrackID, let i = setlist.firstIndex(where: { $0.id == cur }) else { return }
        if playbackTime > 3 || i == 0 { play(trackID: cur) } else { play(trackID: setlist[i - 1].id) }
    }

    func seek(fraction: Double) {
        guard playbackDuration > 0 else { return }
        try? player.seek(to: fraction * playbackDuration)
    }

    private func trackFinished() {
        if autoAdvance { next() }
    }

    func saveSetlist() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Setlist.elcsetlist.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let paths = setlist.map { $0.path }
        if let data = try? JSONEncoder().encode(paths) { try? data.write(to: url) }
    }

    func loadSetlist() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return }
        stopPlayback()
        currentTrackID = nil
        setlist = []
        addTracks(urls: paths.map { URL(fileURLWithPath: $0) })
    }

    // MARK: - Operator controls

    func setFlash(_ on: Bool) { controller.perform { $0.engine.flashHeld = on } }
    func setStrobe(_ on: Bool) { controller.perform { $0.engine.strobeHeld = on } }
    func nextLook() { controller.perform { $0.engine.requestNextLook() } }

    // MARK: - Fixture test / calibration

    func startTest(fixtureID: Int?) {
        testFixtureID = fixtureID
        updateTest()
    }

    private func updateTest() {
        guard let id = testFixtureID else {
            controller.perform { $0.engine.testStates = nil }
            return
        }
        var s = FixtureState()
        s.intensity = 1
        s.color = .white
        s.hybridColor = .open
        s.zoom = 0.3
        switch testPose {
        case .up: s.pan = 0; s.tilt = 0
        case .forward45: s.pan = 0; s.tilt = 45
        case .left: s.pan = -90; s.tilt = 45
        case .right: s.pan = 90; s.tilt = 45
        }
        let states = [id: s]
        controller.perform { $0.engine.testStates = states }
    }

    // MARK: - Internals

    private func refreshUI() {
        let snap = controller.latest
        status = snap.status
        fixtureStates = snap.states
        frames = snap.frames
        packetsSent = controller.packetsSent
        outputError = controller.lastError
        switch mode {
        case .live:
            music = liveInput.analyzer?.state ?? MusicState()
            inputLevel = liveInput.level.get()
        case .setlist:
            music = player.musicState(now: OutputController.monotonicNow())
            inputLevel = player.level.get()
        default:
            inputLevel = player.isPlaying ? player.level.get() : liveInput.level.get()
        }
        isPlaying = player.isPlaying
        playbackTime = max(0, player.currentTime)
        playbackDuration = player.duration
    }

    private func rigChanged() {
        let r = rig
        controller.perform { $0.engine.rig = r }
        scheduleSave()
    }

    private func pushShowSettings() {
        let s = show
        controller.perform { $0.engine.settings = s }
    }

    private func analysisChanged() {
        player.lookahead = analysis.setlistLookahead
        if let la = liveInput.analyzer {
            la.config.latencyCompensation = analysis.latencyCompensation
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.save() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func save() {
        var c = PersistedConfig()
        c.rig = rig
        c.output = output
        c.show = show
        c.analysis = analysis
        c.cid = cid
        c.setlist = setlist
        c.autoAdvance = autoAdvance
        c.rigVersion = PersistedConfig.currentRigVersion
        c.inputDeviceName = inputDevices.first(where: { $0.id == selectedInputID })?.name
        c.save()
    }

    func resetRig() { rig = .elcDefault(universe: rig.fixtures.first?.universe ?? 1) }
}
