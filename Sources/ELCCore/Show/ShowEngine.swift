import Foundation

public enum IdleBehaviour: String, Codable, CaseIterable, Sendable, Identifiable {
    case blackout = "Blackout"
    case ambientGlow = "Ambient glow"
    public var id: String { rawValue }
}

public struct ShowSettings: Codable, Equatable, Sendable {
    public var masterDimmer: Double = 1.0
    public var strobeEnabled: Bool = true
    /// 0...1 maximum strobe speed.
    public var strobeMaxRate: Double = 0.6
    /// Scales the size of all movements (0 = static, 1 = normal, 1.5 = big).
    public var movementAmount: Double = 1.0
    public var colorPolicy: ColorPolicy = .brandMostly
    /// Shifts the energy the engine reacts to (-0.3 calmer ... +0.3 wilder).
    public var energyBias: Double = 0
    /// Multiplier on phrase length (1 = style default, 2 = looks last twice as long).
    public var lookChangeRate: Double = 1
    public var idleBehaviour: IdleBehaviour = .ambientGlow
    public var idleLevel: Double = 0.15
    /// Short blackout right before an analysed drop (setlist mode only).
    public var preDropGap: Bool = true
    public var useGobos: Bool = true
    /// Force a lighting style instead of the detected one.
    public var styleOverride: MusicStyle? = nil
    /// Intensity of the static look.
    public var staticLevel: Double = 0.75

    public init() {}

    enum CodingKeys: String, CodingKey {
        case masterDimmer, strobeEnabled, strobeMaxRate, movementAmount, colorPolicy, energyBias, lookChangeRate,
             idleBehaviour, idleLevel, preDropGap, useGobos, styleOverride, staticLevel
    }

    /// Tolerant decoding so settings saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShowSettings()
        masterDimmer = try c.decodeIfPresent(Double.self, forKey: .masterDimmer) ?? d.masterDimmer
        strobeEnabled = try c.decodeIfPresent(Bool.self, forKey: .strobeEnabled) ?? d.strobeEnabled
        strobeMaxRate = try c.decodeIfPresent(Double.self, forKey: .strobeMaxRate) ?? d.strobeMaxRate
        movementAmount = try c.decodeIfPresent(Double.self, forKey: .movementAmount) ?? d.movementAmount
        colorPolicy = try c.decodeIfPresent(ColorPolicy.self, forKey: .colorPolicy) ?? d.colorPolicy
        energyBias = try c.decodeIfPresent(Double.self, forKey: .energyBias) ?? d.energyBias
        lookChangeRate = try c.decodeIfPresent(Double.self, forKey: .lookChangeRate) ?? d.lookChangeRate
        idleBehaviour = try c.decodeIfPresent(IdleBehaviour.self, forKey: .idleBehaviour) ?? d.idleBehaviour
        idleLevel = try c.decodeIfPresent(Double.self, forKey: .idleLevel) ?? d.idleLevel
        preDropGap = try c.decodeIfPresent(Bool.self, forKey: .preDropGap) ?? d.preDropGap
        useGobos = try c.decodeIfPresent(Bool.self, forKey: .useGobos) ?? d.useGobos
        styleOverride = try c.decodeIfPresent(MusicStyle.self, forKey: .styleOverride)
        staticLevel = try c.decodeIfPresent(Double.self, forKey: .staticLevel) ?? d.staticLevel
    }
}

public enum EngineMode: Equatable, Sendable {
    case off
    case audio
    case mood(String)   // MoodShow id
}

/// Live status for the UI.
public struct EngineStatus: Sendable {
    public var modeName = "Off"
    public var levelName = "-"
    public var section: MusicSection = .silence
    public var lookSummary = ""
    public var paletteName = ""
    public var bpm: Double = 0
    public var beatInBar: Int = 0
    public var bar: Int = 0
    public var phraseProgress: Double = 0
    public var energy: Double = 0
    public var strobing = false
    public var special = ""
    public var styleName = ""
    public var styleIsManual = false
    public var vibe = Vibe()
    public var paused = false
    public var staticOn = false
    /// How dynamic the show is being lit (0 = ballad ... 1 = festival).
    public var drive: Double = 0
    public var finalPeak = false
    public init() {}
}

/// Smooth musical clock: follows the analyser's beat but never jumps or runs backwards
/// (small tempo corrections instead), which removes jitter from every beat-based effect.
struct BeatClock {
    var beat = 0.0
    var bpm = 120.0
    var initialized = false

    mutating func update(target: Double, targetBPM: Double, dt: Double, follow: Bool) {
        if !initialized { beat = target; bpm = targetBPM; initialized = true; return }
        bpm = smoothTowards(bpm, targetBPM, dt: dt, timeConstant: 0.6)
        let advance = dt * bpm / 60
        guard follow else { beat += advance; return }
        let err = target - (beat + advance)
        if abs(err) > 3 {
            // Seek / new track / re-lock: jump (the director hides this with a cue change).
            beat = target
            return
        }
        // Correct the phase by speeding up / slowing down at most 10 %.
        let maxCorr = 0.1 * advance
        beat += advance + clamp(err * 2.5 * dt, -maxCorr, maxCorr)
    }
}

/// Turns music state into fixture states, 44 times per second.
public final class ShowEngine: @unchecked Sendable {
    public var rig: Rig
    public var settings = ShowSettings()
    public var mode: EngineMode = .off

    // Operator overrides (set from the UI)
    public var blackout = false
    public var holdLook = false
    public var flashHeld = false
    public var strobeHeld = false
    /// Freeze the show where it is (clock, cue and positions stop).
    public var paused = false
    /// Fade to the default static look (and back when switched off).
    public var staticLook = false
    /// Calibration / test mode: when set, these states are output as-is (fixtures not listed are dark).
    public var testStates: [Int: FixtureState]? = nil
    private var nextLookRequested = false

    public private(set) var look = Look()
    public private(set) var status = EngineStatus()

    private var rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970))
    private var clock = BeatClock()
    private var prevLook: Look? = nil
    private var fadeStart = 0.0
    private var fadeLen = 0.0
    private var lastBar = Int.min
    private var phraseOriginBar = 0
    private var phrasesSincePalette = 0
    private var level = 1
    private var slowEnergy = 0.5
    private var confirmedSection: MusicSection = .silence
    private var pendingSection: MusicSection? = nil
    private var pendingSince = 0.0
    private var sectionChangePending = false
    private var personality = LightingPersonality.pop
    private var committedStyle: MusicStyle = .pop
    private var styleCandidate: MusicStyle? = nil
    private var styleCandidateSince = 0.0
    private var styleChangePending = false
    private var impactStartBeat: Double? = nil
    private var strobeOnTime = 0.0
    private var strobeCooldown = 0.0
    private var silentFor = 0.0
    private var idleBlend = 0.0
    private var staticBlend = 0.0
    private var frozenShow: [Int: FixtureState]? = nil
    private var post: [Int: PostState] = [:]
    private var lastStates: [Int: FixtureState] = [:]
    private var clockStart: Double? = nil
    private var currentMoodID: String? = nil
    private var lastSource: MusicSource = .none
    private var lastTrackProgress: Double = 0
    /// Current learned snare steps from the music (captured into each new cue).
    private var currentSnare: SnareSteps = .backbeat

    /// A section "slot" of the song: looks are remembered per slot and reused when it repeats
    /// (verse 2 looks like verse 1, every chorus has the chorus look) — like a programmed song.
    struct SectionKey: Hashable { var section: MusicSection; var level: Int }
    private var lookMemory: [SectionKey: Look] = [:]
    private var currentKey: SectionKey? = nil
    private var lastChangeBar = 0
    private var levelCandidate: Int? = nil
    private var levelCandidateBars = 0
    /// How dynamic the current song should be (0 = ballad ... 1 = festival EDM).
    private var drive = 0.5
    private var isFinalPeak = false
    private var entryHitStartBeat: Double? = nil
    private var sectionEnergy: Double? = nil

    struct PostState {
        var pan = 0.0, tilt = 0.0, vPan = 0.0, vTilt = 0.0
        var intensity = 0.0
        var color = RGB.black
        var pixels: [RGB]? = nil
    }

    /// Number of cue changes so far (diagnostics / tests).
    public private(set) var cueChanges = 0

    public init(rig: Rig, seed: UInt64? = nil) {
        self.rig = rig
        if let seed { rng = SeededRandom(seed: seed) }
        look = evolve(Look(), pool: personality.levels[1], palettes: Palette.brandPalettes, full: true, palette: true)
    }

    public func requestNextLook() { nextLookRequested = true }

    public var lastOutput: [Int: FixtureState] { lastStates }

    // MARK: - Tick

    public func tick(music input: MusicState, now: Double, dt: Double) -> [Int: FixtureState] {
        var st = EngineStatus()

        if let test = testStates {
            var out: [Int: FixtureState] = [:]
            for fx in rig.fixtures {
                var s = test[fx.id] ?? (lastStates[fx.id] ?? FixtureState())
                if test[fx.id] == nil { s.intensity = 0 }
                out[fx.id] = s
            }
            st.modeName = "Fixture test"
            st.special = "Test / calibration"
            status = st
            let result = postProcess(out, dt: dt, fast: true, springHz: 1.2, maxSpeed: 120)
            lastStates = result
            return result
        }

        var music = input
        var palettes: [Palette]
        var allowStrobe = settings.strobeEnabled
        var fixedLevel: Int? = nil

        switch mode {
        case .off:
            var out: [Int: FixtureState] = [:]
            for fx in rig.fixtures {
                var s = lastStates[fx.id] ?? FixtureState()
                s.intensity = 0
                s.shutter = .open
                out[fx.id] = s
            }
            st.modeName = "Off"
            status = st
            clockStart = nil
            currentMoodID = nil
            let result = postProcess(out, dt: dt, fast: false, springHz: 0.8, maxSpeed: 60)
            lastStates = result
            return result

        case .mood(let id):
            let mood = MoodShow.all.first { $0.id == id } ?? MoodShow.brandPulse
            if currentMoodID != id || clockStart == nil {
                currentMoodID = id
                clockStart = now - (clock.initialized ? clock.beat * 60 / mood.bpm : 0)
                personality = mood.personality
                level = mood.level
                prevLook = look; fadeStart = clock.beat; fadeLen = 4
                look = evolve(look, pool: personality.levels[level], palettes: mood.palettes, full: true, palette: true)
                phraseOriginBar = lastBar == Int.min ? 0 : lastBar
            }
            music = clockState(bpm: mood.bpm, energy: mood.energy, now: now)
            palettes = mood.palettes
            allowStrobe = allowStrobe && mood.allowsStrobe
            fixedLevel = mood.level
            st.modeName = "Mood: \(mood.name)"
            st.styleName = mood.name

        case .audio:
            if currentMoodID != nil { currentMoodID = nil; clockStart = nil }
            palettes = Palette.forMood(valence: music.vibe.isReady ? music.vibe.valence : 0.6,
                                       arousal: music.vibe.isReady ? music.vibe.arousal : 0.6,
                                       policy: settings.colorPolicy)
            st.modeName = music.source == .track ? "Auto: setlist" : "Auto: live input"
        }

        // --- Clock (frozen while paused)
        if !paused {
            let follow = !(music.isSilent && music.source == .live)
            clock.update(target: music.beat(at: now), targetBPM: music.bpm, dt: dt, follow: follow)
        }
        let beat = clock.beat
        let dbo = Double(music.downbeatOffset)
        let bar = Int(floor((beat - dbo) / 4))
        let barBeat = fmodPositive(beat - dbo, 4)
        currentBar = bar

        // --- Director (frozen while paused)
        if !paused {
            if mode == .audio {
                directAudio(music: music, beat: beat, dt: dt, palettes: palettes)
            }
            if let fl = fixedLevel { level = fl }
            let beatIndex = Int(floor(beat))
            if dropOnNextBeat && beatIndex != lastBeatIndex && lastBeatIndex != Int.min {
                dropOnNextBeat = false
                levelCandidate = nil
                executeDrop(beat: Double(beatIndex), palettes: palettes)
            }
            lastBeatIndex = beatIndex
            if bar != lastBar {
                onBarLine(bar: bar, beat: beat, palettes: palettes)
                lastBar = bar
            }
            if nextLookRequested {
                nextLookRequested = false
                startTransition(full: true, palette: true, fade: max(1, personality.fadeBeats / 2), beat: beat, palettes: palettes)
            }
        }

        // --- Special moments
        var buildProgress: Double? = nil
        var gap = false
        if mode == .audio && !paused {
            if music.source == .track {
                if let toNext = music.beatsToNextSection, music.nextSection == .drop, toNext <= 32, !music.section.isHigh {
                    let len = min(32, max(8, toNext + (beat - music.sectionStartBeat)))
                    if confirmedSection == .build || toNext <= 16 { buildProgress = clamp(1 - toNext / len, 0, 1) }
                }
                let gapStyles: Set<MusicStyle> = [.edm, .house, .drumAndBass, .hipHop, .pop]
                if settings.preDropGap, gapStyles.contains(personality.style), let toNext = music.beatsToNextSection,
                   music.nextSection == .drop, toNext > 0, toNext < 0.5 {
                    gap = true
                }
            } else if confirmedSection == .build {
                buildProgress = clamp((beat - pendingSince) / 32, 0, 1) * 0.7   // live: gentler, never a full ramp
            }
        }
        var entryHit: Double? = nil
        if let start = entryHitStartBeat {
            let since = beat - start
            if since >= 0 && since < 1 { entryHit = since } else if since >= 1 { entryHitStartBeat = nil }
        }
        var impact: Double? = nil
        if let start = impactStartBeat {
            let since = beat - start
            if since >= 0 && since < 2 { impact = since } else if since >= 2 { impactStartBeat = nil }
        }

        // --- Strobe (rare, musical, with safety limits)
        var strobeWanted = false
        if allowStrobe && strobeCooldown <= 0 && personality.strobe != .never {
            if let i = impact, i < 0.5 { strobeWanted = true }
            if music.source == .track, let toNext = music.beatsToNextSection, music.nextSection == .drop,
               toNext < 1.5, toNext > 0.5, !gap { strobeWanted = true }
            if personality.strobe == .peaks && level == 2 {
                let phraseBeat = fmodPositive(beat - dbo, 32)
                let energetic = mode == .audio ? slowEnergy > 0.82 : true
                if phraseBeat >= 31 && energetic { strobeWanted = true }
            }
        }
        if strobeHeld && settings.strobeEnabled { strobeWanted = true }
        if strobeWanted {
            strobeOnTime += dt
            if strobeOnTime > 4 && !strobeHeld { strobeCooldown = 6; strobeOnTime = 0; strobeWanted = false }
        } else {
            strobeOnTime = max(0, strobeOnTime - dt * 0.5)
            strobeCooldown = max(0, strobeCooldown - dt)
        }

        // --- Render the show (or hold it while paused)
        var out: [Int: FixtureState]
        if paused, let frozen = frozenShow {
            out = frozen
        } else {
            out = renderCue(look, beat: beat, barBeat: barBeat, bar: bar)
            if let prev = prevLook, fadeLen > 0 {
                let t = (beat - fadeStart) / fadeLen
                if t >= 1 {
                    prevLook = nil
                } else {
                    let from = renderCue(prev, beat: beat, barBeat: barBeat, bar: bar)
                    out = blendFrames(from, out, clamp(t, 0, 1))
                }
            }
            applyBuildAndImpact(&out, build: buildProgress, impact: impact, beat: beat)
            if let h = entryHit, impact == nil {
                // "Jump to a 10, don't land on it": a one-beat hit as the big section arrives.
                let e = PatternMath.decay(h)
                for fx in rig.fixtures {
                    guard var s = out[fx.id] else { continue }
                    s.intensity = max(s.intensity, e)
                    if fx.kind == .focusFlexL7 { s.color = s.color.mix(look.palette.accent, e * 0.35) }
                    out[fx.id] = s
                }
            }
            frozenShow = out
        }

        // --- Idle (no music): ambient glow or blackout
        if mode == .audio {
            silentFor = music.isSilent ? silentFor + dt : 0
            let threshold = music.source == .track ? 0.3 : 2.5
            let idle = silentFor > threshold
            idleBlend = smoothTowards(idleBlend, idle ? 1 : 0, dt: dt, timeConstant: idle ? 1.2 : 0.4)
            if idle { st.special = "Idle" }
        } else {
            idleBlend = smoothTowards(idleBlend, 0, dt: dt, timeConstant: 0.4)
        }
        if idleBlend > 0.001 {
            let idleFrame = makeIdleFrame(base: out, now: now)
            out = blendFrames(out, idleFrame, idleBlend)
        }

        // --- Static look toggle
        staticBlend = smoothTowards(staticBlend, staticLook ? 1 : 0, dt: dt, timeConstant: 0.6)
        if staticBlend > 0.001 {
            out = blendFrames(out, makeStaticFrame(), staticBlend > 0.995 ? 1 : staticBlend)
        }

        // --- Strobe, operator overrides, master
        let fast = flashHeld || blackout || gap || (impact.map { $0 < 0.25 } ?? false) || (entryHit.map { $0 < 0.2 } ?? false)
        for fx in rig.fixtures {
            guard var s = out[fx.id] else { continue }
            s.shutter = (strobeWanted && staticBlend < 0.5 && idleBlend < 0.5) ? .strobe(settings.strobeMaxRate) : .open
            if gap && staticBlend < 0.5 { s.intensity = 0 }
            if flashHeld {
                s.intensity = 1
                s.color = s.color.mix(.white, 0.4)
                s.pixels = s.pixels.map { $0.map { _ in s.color } }
            }
            s.intensity = clamp(s.intensity * settings.masterDimmer, 0, 1)
            if blackout { s.intensity = 0 }
            if !settings.useGobos { s.gobo = 0; s.staticGobo = 0 }
            out[fx.id] = s
        }

        let p = personality
        let dyn = look.drive
        let result = postProcess(out, dt: dt, fast: fast,
                                 springHz: staticBlend > 0.5 ? 0.6 : p.springHz * (1 + 0.6 * dyn),
                                 maxSpeed: staticBlend > 0.5 ? 60 : min(180, p.maxSpeed * (1 + 0.5 * dyn)),
                                 attack: p.attack * (1 - 0.5 * dyn), release: p.release)

        // --- Status
        st.levelName = ["Low", "Mid", "High"][clamp(level, 0, 2)]
        st.section = mode == .audio ? confirmedSection : .groove
        st.lookSummary = look.summary
        st.paletteName = look.palette.name
        st.bpm = clock.bpm
        st.beatInBar = Int(floor(barBeat))
        st.bar = bar
        st.phraseProgress = fmodPositive(Double(bar - phraseOriginBar) + barBeat / 4, 8) / 8
        st.drive = mode == .audio ? drive : look.drive
        st.finalPeak = look.lift
        st.energy = mode == .audio ? slowEnergy : music.energy
        st.strobing = strobeWanted
        if mode == .audio {
            st.styleName = personality.style.rawValue
            st.styleIsManual = settings.styleOverride != nil
            st.vibe = music.vibe
        }
        if gap { st.special = "Pre-drop gap" }
        else if impact != nil { st.special = "DROP!" }
        else if let bp = buildProgress { st.special = "Build-up \(Int(bp * 100))%" }
        else if entryHit != nil { st.special = "Hit!" }
        else if look.lift && level == 2 { st.special = "Final peak" }
        st.paused = paused
        st.staticOn = staticLook
        if paused { st.special = "Paused" }
        if staticLook { st.special = "Static look" }
        status = st
        lastStates = result
        return result
    }

    // MARK: - Director

    private var effectivePhraseBars: Int {
        max(4, Int((Double(personality.phraseBars) * settings.lookChangeRate).rounded()))
    }

    private func directAudio(music: MusicState, beat: Double, dt: Double, palettes: [Palette]) {
        let isTrack = music.source == .track
        currentSnare = SnareSteps.from(pattern: music.snarePattern, clarity: music.snareClarity)
        // New track (or seek) on the setlist: start fresh with the track's own style.
        if isTrack {
            let prog = music.trackProgress ?? 0
            if lastSource != .track || prog < lastTrackProgress - 0.02 {
                styleChangePending = true
                sectionChangePending = true
                lookMemory = [:]            // new song: new looks
            }
            lastTrackProgress = prog
        }
        lastSource = music.source
        sectionEnergy = isTrack ? music.sectionEnergy : nil
        isFinalPeak = isTrack && music.isFinalPeak
        drive = smoothTowards(drive, computeDrive(music), dt: dt, timeConstant: isTrack ? 0.2 : 4)

        slowEnergy = smoothTowards(slowEnergy, clamp(music.energy + settings.energyBias, 0, 1), dt: dt,
                                   timeConstant: isTrack ? 2 : 5)

        // Style: manual override, or the detected vibe once it's stable.
        let detected = settings.styleOverride ?? (music.vibe.isReady ? music.vibe.style : committedStyle)
        if settings.styleOverride != nil || isTrack {
            if detected != committedStyle { committedStyle = detected; styleChangePending = true }
        } else if detected != committedStyle {
            if styleCandidate != detected { styleCandidate = detected; styleCandidateSince = 0 }
            styleCandidateSince += dt
            if styleCandidateSince > 30 && music.vibe.styleConfidence > 0.3 {
                committedStyle = detected
                styleChangePending = true
                styleCandidate = nil
                lookMemory = [:]            // live: a new style usually means a new song
            }
        } else {
            styleCandidate = nil
        }

        // Live drop event: hit it now, on the beat it landed on (no confirmation wait).
        if !isTrack && music.dropCount != lastDropCount {
            let fresh = music.dropCount > lastDropCount && lastDropCount >= 0
            lastDropCount = music.dropCount
            if fresh && !(confirmedSection == .drop && level == 2) {
                confirmedSection = .drop
                pendingSection = nil
                dropOnNextBeat = false
                sectionChangePending = false
                levelCandidate = nil
                // engine clock and analyser beat agree to within a few ms; take the beat that just started
                let landed = beat - floor(beat) < 0.5 ? floor(beat) : beat
                executeDrop(beat: landed, palettes: palettes)
            }
        }

        // Section confirmation: exact for analysed tracks, debounced for live audio.
        if music.section != .silence && music.section != confirmedSection {
            if isTrack {
                let wasDrop = music.section == .drop
                confirmedSection = music.section
                pendingSince = music.sectionStartBeat
                if wasDrop {
                    executeDrop(beat: beat, palettes: palettes)
                } else {
                    sectionChangePending = true
                }
            } else {
                if pendingSection != music.section { pendingSection = music.section; pendingSince = beat }
                let need: Double = music.section == .drop ? 2 : 8
                if beat - pendingSince >= need {
                    let isDrop = music.section == .drop
                    confirmedSection = music.section
                    pendingSection = nil
                    // Live drop: hit it on the very next beat (not the next bar) so it lands right after the drop.
                    if isDrop { dropOnNextBeat = true }
                    else { sectionChangePending = true }
                }
            }
        } else if music.section == confirmedSection {
            pendingSection = nil
        }
    }

    private var dropOnNextBar = false
    private var lastDropCount = -1
    private var dropOnNextBeat = false
    private var lastBeatIndex = Int.min

    private func targetLevel() -> Int {
        var l = level
        let up: [Double] = [0.42, 0.72]
        let down: [Double] = [0.32, 0.62]
        let e = sectionEnergy.map { clamp($0 + settings.energyBias, 0, 1) } ?? slowEnergy
        while l < 2 && e > up[l] { l += 1 }
        while l > 0 && e < down[l - 1] { l -= 1 }
        switch confirmedSection {
        case .ambient, .breakdown: l = 0
        case .build: l = max(l, 1)
        case .drop, .peak: l = 2
        case .groove: l = max(1, l)
        case .silence: break
        }
        return l
    }

    private func onBarLine(bar: Int, beat: Double, palettes: [Palette]) {
        if mode == .audio {
            // Looks only change on musical boundaries: a new song/style, a new section
            // (verse → chorus, build → drop, ...) or — live — a confirmed change in energy level.
            if styleChangePending {
                styleChangePending = false
                personality = LightingPersonality.for(committedStyle)
                level = targetLevel()
                sectionChangePending = false
                changeToSection(bar: bar, beat: beat, palettes: palettes, fade: personality.fadeBeats)
                return
            }
            if sectionChangePending {
                sectionChangePending = false
                let oldLevel = level
                level = targetLevel()
                levelCandidate = nil
                if dropOnNextBar {
                    dropOnNextBar = false
                    executeDrop(beat: beat, palettes: palettes)
                } else if confirmedSection != .build {
                    let soft = confirmedSection == .breakdown || confirmedSection == .ambient
                    changeToSection(bar: bar, beat: beat, palettes: palettes,
                                    fade: soft ? max(4, personality.fadeBeats) : personality.fadeBeats)
                    if level == 2 && oldLevel < 2 && drive >= 0.35 { entryHitStartBeat = beat }
                }
                return
            }
            // Live: the section label can stay the same while the song clearly steps up or down
            // (verse → chorus). Require the new energy level on two consecutive bar lines.
            if sectionEnergy == nil && !holdLook {
                let t = targetLevel()
                if t != level {
                    if levelCandidate == t { levelCandidateBars += 1 } else { levelCandidate = t; levelCandidateBars = 1 }
                    if levelCandidateBars >= 2 && bar - lastChangeBar >= 4 {
                        let up = t > level
                        level = t
                        levelCandidate = nil
                        changeToSection(bar: bar, beat: beat, palettes: palettes, fade: up ? 1 : max(2, personality.fadeBeats))
                        if up && level == 2 && drive >= 0.35 { entryHitStartBeat = beat }
                        return
                    }
                } else {
                    levelCandidate = nil
                }
            }
            // Safety net for very long sections without any detectable boundary: develop the look
            // (same palette) on a 16-bar line after 64 bars — never in the middle of a phrase.
            let maxBars = max(32, Int(64 * settings.lookChangeRate))
            if !holdLook && bar - lastChangeBar >= maxBars && (bar - lastChangeBar) % 16 == 0 {
                lastChangeBar = bar
                startTransition(full: false, palette: false, fade: personality.fadeBeats, beat: beat, palettes: palettes)
            }
            return
        }
        // Mood shows (no song structure): change on phrase boundaries.
        let phraseBars = effectivePhraseBars
        let barsIn = bar - phraseOriginBar
        if barsIn > 0 && barsIn % phraseBars == 0 && !holdLook {
            let newLevel = mode == .audio ? targetLevel() : level
            let levelChanged = newLevel != level
            level = newLevel
            phrasesSincePalette += 1
            let changePalette = levelChanged || phrasesSincePalette >= 2
            if changePalette { phrasesSincePalette = 0 }
            startTransition(full: levelChanged, palette: changePalette, fade: personality.fadeBeats, beat: beat, palettes: palettes)
        }
    }

    private func executeDrop(beat: Double, palettes: [Palette]) {
        level = 2
        phrasesSincePalette = 0
        if personality.dropImpact { impactStartBeat = beat }
        // Snap to the drop look (no fade). Every drop of the song uses the same look; the last one gets the lift.
        cueChanges += 1
        prevLook = nil
        let key = SectionKey(section: .drop, level: 2)
        if var remembered = lookMemory[key] {
            remembered.lift = isFinalPeak
            look = remembered
        } else {
            look = evolve(look, pool: personality.levels[2], palettes: palettes, full: true, palette: true)
            lookMemory[key] = look
            look.lift = isFinalPeak
        }
        currentKey = key
        phraseOriginBar = currentBar
        lastChangeBar = currentBar
    }

    /// Switches to the look of the current section — the remembered one if this section already
    /// occurred in the song (verse, chorus...), otherwise a new look that is stored for its repeats.
    private func changeToSection(bar: Int, beat: Double, palettes: [Palette], fade: Double) {
        let key = SectionKey(section: confirmedSection, level: level)
        phraseOriginBar = bar
        lastChangeBar = bar
        if key == currentKey && prevLook == nil && !lookMemory.isEmpty { return }
        let next: Look
        if var remembered = lookMemory[key], palettes.contains(remembered.palette) {
            remembered.lift = isFinalPeak && level == 2
            next = remembered
        } else {
            var fresh = evolve(look, pool: personality.levels[clamp(level, 0, 2)], palettes: palettes, full: true,
                               palette: lookMemory.isEmpty || key.level != currentKey?.level || confirmedSection == .breakdown)
            fresh.lift = false
            lookMemory[key] = fresh
            fresh.lift = isFinalPeak && level == 2
            next = fresh
        }
        currentKey = key
        cueChanges += 1
        if fade > 0 { prevLook = look; fadeStart = beat; fadeLen = fade } else { prevLook = nil }
        look = next
    }

    /// How dynamic the music should be lit: style baseline, adjusted by mood and "electronic-ness".
    private func computeDrive(_ music: MusicState) -> Double {
        let base: [MusicStyle: Double] = [.edm: 0.95, .house: 0.8, .drumAndBass: 0.9, .pop: 0.62, .latin: 0.65,
                                          .hipHop: 0.55, .rock: 0.72, .ballad: 0.1, .ambient: 0.0]
        var d = base[personality.style] ?? 0.5
        let v = music.vibe
        let hasBeat = music.source == .track ? music.tempoConfidence > 0.5 : music.tempoConfidence > 0.3
        if v.isReady {
            d += 0.35 * (v.arousal - 0.5) + 0.2 * (v.valence - 0.5)
            if hasBeat && personality.style != .ballad && personality.style != .ambient { d += 0.25 * v.electronic }
        }
        if !hasBeat { d *= 0.5 }
        return clamp(d, 0, 1)
    }

    private var currentBar = 0

    private func startTransition(full: Bool, palette: Bool, fade: Double, beat: Double, palettes: [Palette]) {
        let pool = personality.levels[clamp(level, 0, 2)]
        let next = evolve(look, pool: pool, palettes: palettes, full: full, palette: palette)
        cueChanges += 1
        if fade > 0 {
            prevLook = look
            fadeStart = beat
            fadeLen = fade
        } else {
            prevLook = nil
        }
        look = next
    }

    private func pick<T: Equatable>(_ options: [T], avoiding current: T) -> T {
        guard !options.isEmpty else { return current }
        let filtered = options.count > 1 ? options.filter { $0 != current } : options
        return filtered[Int(rng.unit() * Double(filtered.count)) % filtered.count]
    }

    private func pickValue(_ options: [Double]) -> Double {
        guard !options.isEmpty else { return 1 }
        return options[Int(rng.unit() * Double(options.count)) % options.count]
    }

    /// Changes a cue. A partial evolve changes only one or two aspects so the show feels continuous.
    private func evolve(_ l: Look, pool: LookPool, palettes: [Palette], full: Bool, palette: Bool) -> Look {
        var n = l
        n.level = pool.level
        n.depth = pool.depth
        if palette || !palettes.contains(n.palette) { n.palette = pick(palettes, avoiding: l.palette) }
        var aspects: Set<Int> = full ? Set(0..<6) : [Int(rng.unit() * 6) % 6]
        if !full && rng.unit() < 0.5 { aspects.insert(Int(rng.unit() * 6) % 6) }
        if aspects.contains(0) || !pool.l7Color.contains(n.l7Color) { n.l7Color = pick(pool.l7Color, avoiding: l.l7Color) }
        if aspects.contains(1) || !pool.l7Intensity.contains(n.l7Intensity) || !pool.chaseRates.contains(n.chaseRate) {
            let snareOptions = pool.l7Intensity.filter { $0.isSnare }
            // Songs with a clear snare groove (pop, rock, hip-hop...): usually let the L7s follow the snare.
            let energetic: Set<IntensityPattern> = [.pulse, .chase, .bounce, .centerOut, .snareHit, .snareChase, .snareAlternate, .alternate]
            let energeticOptions = pool.l7Intensity.filter { energetic.contains($0) }
            if currentSnare.learned && !snareOptions.isEmpty && rng.unit() < 0.6 {
                n.l7Intensity = pick(snareOptions, avoiding: l.l7Intensity)
            } else if drive > 0.65 && level >= 1 && !energeticOptions.isEmpty {
                // Uplifting / electronic songs with a beat: keep the L7s moving with the rhythm.
                n.l7Intensity = pick(energeticOptions, avoiding: l.l7Intensity)
            } else {
                n.l7Intensity = pick(pool.l7Intensity, avoiding: l.l7Intensity)
            }
            n.chaseRate = pickValue(pool.chaseRates)
        }
        if aspects.contains(2) || !pool.l7Move.contains(n.l7Move) || !pool.cycleBeats.contains(n.moveCycleBeats) {
            n.l7Move = pick(pool.l7Move, avoiding: l.l7Move)
            n.moveCycleBeats = pickValue(pool.cycleBeats)
            n.l7Zoom = lerp(pool.l7Zoom.lowerBound, pool.l7Zoom.upperBound, rng.unit())
        }
        if aspects.contains(3) || !pool.hybridColor.contains(n.hybridColor) { n.hybridColor = pick(pool.hybridColor, avoiding: l.hybridColor) }
        var beams = pool.hybridBeam
        if !settings.useGobos { beams = beams.filter { ![.goboSpin, .goboPrism, .softGobo].contains($0) } }
        if beams.isEmpty { beams = [.beam] }
        if aspects.contains(4) || !beams.contains(n.hybridBeam) {
            n.hybridBeam = pick(beams, avoiding: l.hybridBeam)
            n.gobo = Int(pickValue(pool.gobos.map(Double.init)))
            n.hybridZoom = lerp(pool.hybridZoom.lowerBound, pool.hybridZoom.upperBound, rng.unit())
        }
        if aspects.contains(5) || !pool.hybridIntensity.contains(n.hybridIntensity) || !pool.hybridMove.contains(n.hybridMove) {
            n.hybridIntensity = pick(pool.hybridIntensity, avoiding: l.hybridIntensity)
            n.hybridMove = pick(pool.hybridMove, avoiding: l.hybridMove)
        }
        n.l7Zoom = clamp(n.l7Zoom, pool.l7Zoom.lowerBound, pool.l7Zoom.upperBound)
        n.hybridZoom = clamp(n.hybridZoom, pool.hybridZoom.lowerBound, pool.hybridZoom.upperBound)
        n.snare = currentSnare
        // L7 pixel layer: only one moving layer at a time — a chase across the bars gets static
        // pixels, a steady/pulsing bar may get a moving pixel effect inside it.
        let movingIntensity: Set<IntensityPattern> = [.chase, .bounce, .wave, .breathe, .snareChase, .centerOut]
        var pixelOptions = pool.l7Pixels
        if movingIntensity.contains(n.l7Intensity) { pixelOptions = pixelOptions.filter { !$0.isMoving } }
        if pixelOptions.isEmpty { pixelOptions = [.solid] }
        if full || aspects.contains(0) || aspects.contains(1) || !pixelOptions.contains(n.l7Pixels) {
            n.l7Pixels = pick(pixelOptions, avoiding: l.l7Pixels)
        }
        // Energy / dynamics of the look follow the song's drive.
        let d = mode == .audio ? drive : (personality.style == .edm ? 0.9 : 0.5)
        n.drive = d
        n.movementSize = personality.movementSize * (0.85 + 0.45 * d)
        n.depth = clamp(pool.depth + 0.25 * d * (level == 2 ? 1 : 0.4), 0, 0.85)
        if d > 0.6, let shortest = pool.cycleBeats.min(), level >= 1 { n.moveCycleBeats = shortest }
        if level == 2 { n.l7Zoom = lerp(n.l7Zoom, pool.l7Zoom.lowerBound, d * 0.6) }
        // Contrast: in low sections one group carries the look and the other stays in the background.
        switch level {
        case 0: n.featured = rng.unit() < 0.5 ? .l7 : .hybrids
        case 1: n.featured = d > 0.5 ? .both : (rng.unit() < 0.5 ? .l7 : .both)
        default: n.featured = .both
        }
        return n
    }

    // MARK: - Rendering

    private func renderCue(_ c: Look, beat: Double, barBeat: Double, bar: Int) -> [Int: FixtureState] {
        var out: [Int: FixtureState] = [:]
        let p = personality
        let fxBeat = p.halfTime ? beat / 2 : beat
        let amount = settings.movementAmount * c.movementSize * (c.lift ? 1.15 : 1)
        let levelFactor = [0.3, 0.7, 1.0][clamp(level, 0, 2)]
        let accentAmt = p.accentAmount * levelFactor * (1 + 1.5 * c.drive) * (c.lift ? 1.3 : 1)
        let accent = PatternMath.accent(p.accent, barBeat: barBeat, beat: beat) * accentAmt
        // Background level of the non-featured group ("darkness is free").
        let background = level == 0 ? 0.25 + 0.35 * (1 - c.drive) : 0.75
        let l7Scale = c.featured == .hybrids ? background : 1.0
        let hybridScale = c.featured == .l7 ? background : 1.0
        let l7s = rig.l7s
        let hybrids = rig.hybrids

        for (i, fx) in l7s.enumerated() {
            let n = l7s.count
            let x = n > 1 ? Double(i) / Double(n - 1) * 2 - 1 : 0
            var s = FixtureState()
            s.color = PatternMath.l7Color(c.l7Color, palette: c.palette, beat: fxBeat, barBeat: barBeat, bar: bar,
                                          index: i, x: x, fadeBeats: p.colorFadeBeats)
            let pat = PatternMath.intensity(c.l7Intensity, beat: fxBeat, barBeat: barBeat, bar: bar, index: i, count: n,
                                            rate: c.chaseRate, cycle: c.moveCycleBeats, x: x, snare: c.snare)
            let depth = c.l7Intensity.isSnare ? max(c.depth, 0.65) : c.depth
            s.intensity = clamp((c.level * (1 - depth + depth * pat) + (c.l7Intensity.isSnare ? 0 : accent)) * l7Scale, 0, 1)
            s.pixels = PatternMath.l7Pixels(c.l7Pixels, palette: c.palette, colour: s.color, bar: i, bars: n,
                                            beat: fxBeat, barBeat: barBeat, cycle: c.moveCycleBeats)
            let aim = PatternMath.l7Aim(c.l7Move, beat: fxBeat, index: i, x: x, cycle: c.moveCycleBeats, amount: amount)
            s.pan = aim.0; s.tilt = aim.1
            s.zoom = c.l7Zoom
            out[fx.id] = s
        }

        // Hybrid chase order follows the V: 5, 3, 1, 2, 4, 6
        let vOrder = [5, 3, 1, 2, 4, 6]
        for (k, fx) in hybrids.enumerated() {
            let number = k + 1
            let side = number % 2 == 1 ? -1 : 1
            let row = (number - 1) / 2
            let chaseIndex = vOrder.firstIndex(of: number) ?? k
            let x = Double(chaseIndex) / 2.5 - 1
            var s = FixtureState()
            s.color = PatternMath.hybridColor(c.hybridColor, palette: c.palette, side: side, row: row)
            s.hybridColor = HybridColor.nearest(to: s.color)
            let pat = PatternMath.intensity(c.hybridIntensity, beat: fxBeat, barBeat: barBeat, bar: bar, index: chaseIndex,
                                            count: hybrids.count, rate: c.chaseRate * 0.5, cycle: c.moveCycleBeats, x: x, snare: c.snare)
            let hDepth = c.hybridIntensity.isSnare ? max(c.depth, 0.5) : c.depth * 0.8
            s.intensity = clamp((c.level * (1 - hDepth + hDepth * pat) + accent * 0.6) * hybridScale, 0, 1)
            let aim = PatternMath.hybridAim(c.hybridMove, beat: fxBeat, number: number, side: side, row: row,
                                            cycle: c.moveCycleBeats, amount: amount)
            s.pan = aim.0; s.tilt = aim.1
            PatternMath.applyBeam(c.hybridBeam, gobo: c.gobo, to: &s, side: side)
            s.zoom = c.hybridBeam == .wash ? max(0.7, c.hybridZoom) : c.hybridZoom
            out[fx.id] = s
        }
        return out
    }

    private func applyBuildAndImpact(_ out: inout [Int: FixtureState], build: Double?, impact: Double?, beat: Double) {
        let energetic: Set<MusicStyle> = [.edm, .house, .drumAndBass, .pop, .hipHop, .latin, .rock]
        if let p = build {
            let sub: Double = energetic.contains(personality.style) ? (p < 0.5 ? 1 : (p < 0.85 ? 2 : 4)) : 1
            let riser = PatternMath.decay(fmodPositive(beat * sub, 1))
            for (i, fx) in rig.l7s.enumerated() {
                guard var s = out[fx.id] else { continue }
                let x = rig.l7s.count > 1 ? Double(i) / Double(rig.l7s.count - 1) * 2 - 1 : 0
                let target = (0.45 + 0.35 * p) + (0.2 + 0.15 * p) * riser
                s.intensity = lerp(s.intensity, target, smoothstep(p * 1.5))
                s.color = s.color.mix(look.palette.accent, p * 0.6)
                // The bars "charge up": pixels light from each bar's centre outwards as the build progresses.
                let base = s.color
                s.pixels = (0..<7).map { px in
                    let d = abs(Double(px) - 3) / 3
                    let lit = PatternMath.window(max(0, d - p * 1.1), 0.25)
                    return base.scaled(0.1 + 0.9 * lit)
                }
                s.pan = lerp(s.pan, x * 28, p * 0.8)
                s.tilt = lerp(s.tilt, 8, p * 0.8)
                s.zoom = lerp(s.zoom, 0, p)
                out[fx.id] = s
            }
            for (k, fx) in rig.hybrids.enumerated() {
                guard var s = out[fx.id] else { continue }
                let side = (k + 1) % 2 == 1 ? -1.0 : 1.0
                let row = Double(k / 2)
                s.intensity = lerp(s.intensity, 0.5 + 0.5 * p, p)
                s.zoom = lerp(s.zoom, 0, p)
                s.frost = s.frost * (1 - p)
                s.pan = lerp(s.pan, side * 62, p * 0.8)
                s.tilt = lerp(s.tilt, 12 + row * 6, p * 0.8)
                out[fx.id] = s
            }
        }
        if let imp = impact {
            let e = PatternMath.decay(imp / 2)
            for fx in rig.fixtures {
                guard var s = out[fx.id] else { continue }
                s.intensity = max(s.intensity, e)
                if fx.kind == .focusFlexL7 {
                    s.color = s.color.mix(.white, e * 0.5)
                    s.pixels = s.pixels.map { $0.map { px in px.mix(s.color, e) } }
                }
                out[fx.id] = s
            }
        }
    }

    /// Crossfade between two frames. Hybrid wheel/gobo/prism changes happen "in black":
    /// the fixture dims out on the old settings and fades up on the new ones.
    private func blendFrames(_ a: [Int: FixtureState], _ b: [Int: FixtureState], _ t: Double) -> [Int: FixtureState] {
        var out: [Int: FixtureState] = [:]
        let e = smoothstep(t)
        for fx in rig.fixtures {
            guard let sa = a[fx.id] else { out[fx.id] = b[fx.id]; continue }
            guard let sb = b[fx.id] else { out[fx.id] = sa; continue }
            var o = sb
            o.pan = lerp(sa.pan, sb.pan, e)
            o.tilt = lerp(sa.tilt, sb.tilt, e)
            o.zoom = lerp(sa.zoom, sb.zoom, e)
            o.frost = lerp(sa.frost, sb.frost, e)
            o.color = sa.color.mix(sb.color, e)
            if sa.pixels != nil || sb.pixels != nil {
                let pa = sa.pixels ?? Array(repeating: sa.color, count: 7)
                let pb = sb.pixels ?? Array(repeating: sb.color, count: 7)
                o.pixels = zip(pa, pb).map { $0.mix($1, e) }
            }
            o.goboRotation = lerp(sa.goboRotation, sb.goboRotation, e)
            o.prismRotation = lerp(sa.prismRotation, sb.prismRotation, e)
            let discreteDiffers = fx.kind == .focusHybrid &&
                ((sa.hybridColor ?? HybridColor.nearest(to: sa.color)) != (sb.hybridColor ?? HybridColor.nearest(to: sb.color))
                 || sa.gobo != sb.gobo || sa.prism != sb.prism || sa.staticGobo != sb.staticGobo)
            if discreteDiffers {
                if t < 0.5 {
                    o.hybridColor = sa.hybridColor ?? HybridColor.nearest(to: sa.color)
                    o.gobo = sa.gobo; o.prism = sa.prism; o.staticGobo = sa.staticGobo; o.goboShake = sa.goboShake
                    o.goboRotation = sa.goboRotation; o.prismRotation = sa.prismRotation
                    o.intensity = sa.intensity * (1 - smoothstep(t * 2))
                } else {
                    o.intensity = sb.intensity * smoothstep(t * 2 - 1)
                }
            } else {
                o.intensity = lerp(sa.intensity, sb.intensity, e)
            }
            o.shutter = t < 0.5 ? sa.shutter : sb.shutter
            out[fx.id] = o
        }
        return out
    }

    /// The default static look: brand colours, calm fan, no movement.
    public func makeStaticFrame() -> [Int: FixtureState] {
        var out: [Int: FixtureState] = [:]
        let lvl = settings.staticLevel
        for (i, fx) in rig.l7s.enumerated() {
            let n = rig.l7s.count
            let x = n > 1 ? Double(i) / Double(n - 1) * 2 - 1 : 0
            var s = FixtureState()
            s.color = i % 2 == 0 ? .brandGreen : .brandMagenta
            s.intensity = lvl
            s.pan = x * 22
            s.tilt = 20
            s.zoom = 0.7
            out[fx.id] = s
        }
        for (k, fx) in rig.hybrids.enumerated() {
            let number = k + 1
            let side = number % 2 == 1 ? -1.0 : 1.0
            let row = Double(k / 2)
            var s = FixtureState()
            s.color = side < 0 ? .brandGreen : .brandMagenta
            s.hybridColor = side < 0 ? .green : .magenta
            s.intensity = lvl
            s.pan = side * 60
            s.tilt = 16 + row * 6
            s.zoom = 0.45
            s.frost = 0.3
            out[fx.id] = s
        }
        return out
    }

    private func makeIdleFrame(base: [Int: FixtureState], now: Double) -> [Int: FixtureState] {
        var out = base
        for fx in rig.fixtures {
            guard var s = out[fx.id] else { continue }
            if settings.idleBehaviour == .ambientGlow {
                let c: RGB = fx.id % 2 == 0 ? .brandGreen : .brandMagenta
                s.color = c
                s.pixels = nil
                s.hybridColor = HybridColor.nearest(to: c)
                s.intensity = settings.idleLevel * (0.7 + 0.3 * sin(now * 0.35 + Double(fx.id) * 0.5))
                if fx.kind == .focusHybrid { s.frost = 0.7; s.gobo = 0; s.prism = 0 }
                s.zoom = 1
            } else {
                s.intensity = 0
            }
            out[fx.id] = s
        }
        return out
    }

    // MARK: - Post processing: physical movement + intensity slew

    private func postProcess(_ frame: [Int: FixtureState], dt: Double, fast: Bool, springHz: Double, maxSpeed: Double,
                             attack: Double = 0.1, release: Double = 0.3) -> [Int: FixtureState] {
        var out = frame
        let w = 2 * Double.pi * springHz
        for fx in rig.fixtures {
            guard var s = out[fx.id] else { continue }
            // Keep the target wall-safe before smoothing.
            let safe = BeamGeometry.safeAim(pan: s.pan, tilt: s.tilt, calibration: fx.calibration)
            var p = post[fx.id] ?? PostState(pan: safe.pan, tilt: safe.tilt, vPan: 0, vTilt: 0, intensity: 0, color: s.color)
            // Critically damped spring with a speed limit → smooth, physical-looking moves.
            let aPan = w * w * (safe.pan - p.pan) - 2 * w * p.vPan
            let aTilt = w * w * (safe.tilt - p.tilt) - 2 * w * p.vTilt
            p.vPan = clamp(p.vPan + aPan * dt, -maxSpeed, maxSpeed)
            p.vTilt = clamp(p.vTilt + aTilt * dt, -maxSpeed, maxSpeed)
            p.pan += p.vPan * dt
            p.tilt += p.vTilt * dt
            // Intensity slew limiting (no hard steps).
            let up = fast ? dt / 0.03 : dt / max(attack, 0.02)
            let down = fast ? dt / 0.05 : dt / max(release, 0.02)
            let d = s.intensity - p.intensity
            p.intensity += d > 0 ? min(d, up) : max(d, -down)
            let k = fast ? 1 : 1 - exp(-dt / 0.08)
            p.color = p.color.mix(s.color, k)
            if fx.kind == .focusFlexL7 {
                let target = s.pixels ?? Array(repeating: s.color, count: 7)
                let cur = p.pixels ?? target
                p.pixels = zip(cur, target).map { $0.mix($1, k) }
                s.pixels = p.pixels
            }
            post[fx.id] = p
            let aim = BeamGeometry.safeAim(pan: p.pan, tilt: p.tilt, calibration: fx.calibration)
            s.pan = aim.pan; s.tilt = aim.tilt
            s.intensity = clamp(p.intensity, 0, 1)
            s.color = p.color
            out[fx.id] = s
        }
        return out
    }

    private func clockState(bpm: Double, energy: Double, now: Double) -> MusicState {
        var s = MusicState()
        s.source = .clock
        s.timestamp = now
        s.bpm = bpm
        s.beatPosition = (now - (clockStart ?? now)) * bpm / 60
        s.energy = energy
        s.section = .groove
        s.isSilent = false
        s.tempoConfidence = 1
        return s
    }
}
