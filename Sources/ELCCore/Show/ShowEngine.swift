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
    public var strobeMaxRate: Double = 0.7
    /// Scales the size of all movements (0 = static, 1 = normal, 1.5 = big).
    public var movementAmount: Double = 1.0
    public var colorPolicy: ColorPolicy = .brandMostly
    /// Shifts the energy the engine reacts to (-0.3 calmer ... +0.3 wilder).
    public var energyBias: Double = 0
    /// Multiplier on how often looks change (0.5 = twice as often, 2 = half as often).
    public var lookChangeRate: Double = 1
    public var idleBehaviour: IdleBehaviour = .ambientGlow
    public var idleLevel: Double = 0.15
    /// Short blackout right before an analysed drop (setlist mode only).
    public var preDropGap: Bool = true
    public var useGobos: Bool = true

    public init() {}
}

public enum EngineMode: Equatable, Sendable {
    case off
    case audio
    case mood(String)   // MoodShow id
}

/// Live status for the UI.
public struct EngineStatus: Sendable {
    public var modeName = "Off"
    public var tierName = "-"
    public var section: MusicSection = .silence
    public var lookSummary = ""
    public var paletteName = ""
    public var bpm: Double = 0
    public var beatInBar: Int = 0
    public var bar: Int = 0
    public var energy: Double = 0
    public var strobing = false
    public var special = ""
    public init() {}
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
    private var nextLookRequested = false
    /// Calibration / test mode: when set, these states are output as-is (fixtures not listed are dark).
    public var testStates: [Int: FixtureState]? = nil

    public private(set) var look = Look()
    public private(set) var status = EngineStatus()

    private var rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970))
    private var lastBar = Int.min
    private var lastSection: MusicSection = .silence
    private var phraseOriginBar = 0
    private var barsSinceLook = 0
    private var barsSincePalette = 0
    private var smoothedEnergy = 0.0
    private var tier = 0
    private var lastKickCount = 0
    private var kickEnv = 0.0
    private var impactStartBeat: Double? = nil
    private var strobeOnTime = 0.0
    private var strobeCooldown = 0.0
    private var aimState: [Int: (pan: Double, tilt: Double)] = [:]
    private var colorState: [Int: RGB] = [:]
    private var lastStates: [Int: FixtureState] = [:]
    private var clockStart: Double? = nil
    private var currentMoodID: String? = nil
    private var idleLevelState = 0.0

    public init(rig: Rig) {
        self.rig = rig
        look = makeLook(pool: .groove, palettes: Palette.brandPalettes)
    }

    public func requestNextLook() { nextLookRequested = true }

    public var lastOutput: [Int: FixtureState] { lastStates }

    // MARK: - Tick

    public func tick(music input: MusicState, now: Double, dt: Double) -> [Int: FixtureState] {
        var out: [Int: FixtureState] = [:]
        var music = input
        var pool: LookPool
        var palettes: [Palette]
        var moodMovement = 1.0
        var allowStrobe = settings.strobeEnabled
        var st = EngineStatus()

        if let test = testStates {
            for fx in rig.fixtures {
                var s = test[fx.id] ?? (lastStates[fx.id] ?? FixtureState())
                if test[fx.id] == nil { s.intensity = 0 }
                out[fx.id] = s
            }
            st.modeName = "Fixture test"
            st.special = "Test / calibration"
            status = st
            lastStates = out
            return out
        }

        switch mode {
        case .off:
            for fx in rig.fixtures {
                var s = lastStates[fx.id] ?? FixtureState()
                s.intensity = 0
                out[fx.id] = s
            }
            st.modeName = "Off"
            status = st
            lastStates = out
            clockStart = nil
            return out

        case .mood(let id):
            let mood = MoodShow.all.first { $0.id == id } ?? MoodShow.brandPulse
            if currentMoodID != id || clockStart == nil {
                currentMoodID = id
                clockStart = now
                lastBar = Int.min
                barsSinceLook = 1_000
                barsSincePalette = 1_000
            }
            music = clockState(bpm: mood.bpm, energy: mood.energy, now: now)
            pool = mood.pool
            palettes = mood.palettes
            moodMovement = mood.movementScale
            allowStrobe = allowStrobe && mood.allowsStrobe
            st.modeName = "Mood: \(mood.name)"

        case .audio:
            currentMoodID = nil
            clockStart = nil
            let e = clamp(input.energy + settings.energyBias, 0, 1)
            smoothedEnergy = smoothTowards(smoothedEnergy, e, dt: dt, timeConstant: 1.2)
            tier = computeTier(energy: smoothedEnergy, section: input.section, current: tier)
            pool = LookPool.tier(tier)
            palettes = palettesForPolicy(calm: tier == 0)
            st.modeName = input.source == .track ? "Auto: setlist" : "Auto: live input"
        }

        let beat = music.beat(at: now)
        let barF = (beat - Double(music.downbeatOffset)) / 4
        let bar = Int(floor(barF))
        let beatInBar = music.beatInBar(beat)

        // Kick envelope (from live analysis or the playback tap)
        if music.kickCount != lastKickCount {
            if music.kickCount > lastKickCount || music.kickCount < lastKickCount - 1000 { kickEnv = 1 }
            lastKickCount = music.kickCount
        }
        kickEnv *= exp(-dt / 0.13)

        // Idle / silence handling (audio mode only)
        let idle = mode == .audio && (music.isSilent || music.section == .silence)
        idleLevelState = smoothTowards(idleLevelState, idle ? 1 : 0, dt: dt, timeConstant: idle ? 1.5 : 0.15)

        // Section changes and look director
        if mode == .audio && music.section != lastSection {
            handleSectionChange(from: lastSection, to: music.section, beat: beat, bar: bar, music: music, pool: pool, palettes: palettes)
            lastSection = music.section
        }
        if bar != lastBar {
            if lastBar != Int.min {
                barsSinceLook += 1
                barsSincePalette += 1
            }
            lastBar = bar
            let every = max(1, Int((Double(pool.changeEveryBars) * settings.lookChangeRate).rounded()))
            if !holdLook && barsSinceLook >= every && (bar - phraseOriginBar) % every == 0 {
                let changePalette = barsSincePalette >= every * 2
                look = evolve(look, pool: pool, palettes: palettes, full: barsSinceLook > every * 4, palette: changePalette)
                barsSinceLook = 0
                if changePalette { barsSincePalette = 0 }
            }
        }
        if nextLookRequested {
            nextLookRequested = false
            look = evolve(look, pool: pool, palettes: palettes, full: true, palette: true)
            barsSinceLook = 0
            barsSincePalette = 0
        }

        // Special moments (build-up / drop impact)
        var buildProgress: Double? = nil
        var gap = false
        if mode == .audio {
            if music.section == .build {
                if let toNext = music.beatsToNextSection, music.nextSection == .drop || music.nextSection == .peak {
                    let len = min(32, max(4, toNext + (beat - music.sectionStartBeat)))
                    buildProgress = clamp(1 - toNext / len, 0, 1)
                } else {
                    buildProgress = clamp((beat - music.sectionStartBeat) / 32, 0, 1)
                }
            } else if let toNext = music.beatsToNextSection, music.nextSection == .drop, toNext <= 16, !music.section.isHigh {
                buildProgress = clamp(1 - toNext / 16, 0, 1)
            }
            if settings.preDropGap, let toNext = music.beatsToNextSection, music.nextSection == .drop, toNext > 0, toNext < 0.5 {
                gap = true
            }
        }
        var impact: Double? = nil
        if let start = impactStartBeat {
            let since = beat - start
            if since >= 0 && since < 1.5 { impact = since } else if since >= 1.5 { impactStartBeat = nil }
        }

        // Strobe safety: never more than 4 s continuously, then 6 s rest.
        var strobeWanted = false
        if allowStrobe && strobeCooldown <= 0 {
            if let p = buildProgress, p > 0.82 { strobeWanted = true }
            if let i = impact, i < 0.5 { strobeWanted = true }
            if mode != .audio || tier >= 3 {
                // short strobe hit on the last beat of every 4-bar phrase at peak energy
                let phraseBeat = fmodPositive(beat - Double(music.downbeatOffset), 16)
                if phraseBeat >= 15 && (mode == .audio ? smoothedEnergy > 0.85 : true) { strobeWanted = true }
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

        // Render
        let l7s = rig.l7s
        let hybrids = rig.hybrids
        let amount = settings.movementAmount * moodMovement
        let energyScale = mode == .audio ? (0.55 + 0.45 * smoothedEnergy) : 1.0
        let strobeRate = clamp(settings.strobeMaxRate * (buildProgress.map { 0.4 + 0.6 * $0 } ?? 1), 0, 1)

        for (i, fx) in l7s.enumerated() {
            let n = l7s.count
            let x = n > 1 ? (Double(i) / Double(n - 1)) * 2 - 1 : 0
            var s = FixtureState()
            var col = PatternMath.l7Color(look.l7Color, palette: look.palette, beat: beat, index: i, x: x)
            var level = PatternMath.intensity(look.l7Intensity, beat: beat, index: i, count: n, rate: look.chaseRate,
                                              cycle: look.moveCycleBeats, kickEnv: kickEnv, x: x)
            level = look.floor + (1 - look.floor) * level
            var aim = PatternMath.l7Aim(look.l7Move, beat: beat, index: i, x: x, cycle: look.moveCycleBeats, amount: amount)
            var zoom = look.l7Zoom
            if let p = buildProgress {
                // Build-up: accelerating chase, rising beams, colours converge to the accent.
                let rate = pow(2, floor(p * 3.99))
                let chase = PatternMath.intensity(.chase, beat: beat, index: i, count: n, rate: rate, cycle: 4, kickEnv: 0, x: x)
                level = (0.25 + 0.5 * p) + (0.75 - 0.5 * p) * chase * (1 - p) + p * 0.25
                col = col.mix(look.palette.accent, p * 0.7)
                aim = (lerp(aim.0, x * 30, p), lerp(aim.1, 6, p))
                zoom = lerp(zoom, 0.0, p)
            }
            if let imp = impact {
                level = max(level, exp(-imp * 1.5))
                col = col.mix(.white, max(0, 0.6 - imp * 0.6))
                zoom = 1
            }
            s.color = smoothColor(fx.id, col, dt: dt, tc: impact != nil ? 0.02 : look.colorFade)
            s.intensity = level * energyScale
            s.zoom = zoom
            s.shutter = strobeWanted ? .strobe(strobeRate) : .open
            let a = smoothAim(fx.id, aim, dt: dt, tc: look.moveSmoothing, calibration: fx.calibration)
            s.pan = a.pan; s.tilt = a.tilt
            s.moveSmoothing = look.moveSmoothing > 1 ? 0.5 : 0
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
            var col = PatternMath.hybridColor(look.hybridColor, palette: look.palette, bar: bar, side: side, row: row)
            var level = PatternMath.intensity(look.hybridIntensity, beat: beat, index: chaseIndex, count: hybrids.count,
                                              rate: look.chaseRate, cycle: look.moveCycleBeats, kickEnv: kickEnv, x: x)
            level = look.floor + (1 - look.floor) * level
            var aim = PatternMath.hybridAim(look.hybridMove, beat: beat, number: number, side: side, row: row,
                                            cycle: look.moveCycleBeats, amount: amount)
            applyBeam(look.hybridBeam, to: &s, side: side)
            s.zoom = look.hybridBeam == .wash ? max(0.7, look.hybridZoom) : look.hybridZoom
            if let p = buildProgress {
                aim = (lerp(aim.0, Double(side) * 65, p), lerp(aim.1, 12 + Double(row) * 6, p))
                s.zoom = lerp(s.zoom, 0, p)
                s.frost = 0
                level = 0.3 + 0.7 * p
                col = col.mix(look.palette.accent, p > 0.75 ? 1 : 0)
            }
            if let imp = impact {
                level = max(level, exp(-imp * 1.2))
            }
            s.color = col
            s.hybridColor = HybridColor.nearest(to: col)
            s.intensity = level * energyScale
            s.shutter = strobeWanted ? .strobe(strobeRate) : .open
            let a = smoothAim(fx.id, aim, dt: dt, tc: look.moveSmoothing, calibration: fx.calibration)
            s.pan = a.pan; s.tilt = a.tilt
            s.moveSmoothing = look.moveSmoothing > 1 ? 0.5 : 0
            out[fx.id] = s
        }

        // Idle (no music): blend to a slow ambient glow or blackout.
        if idleLevelState > 0.001 {
            let t = now
            for fx in rig.fixtures {
                guard var s = out[fx.id] else { continue }
                var idleIntensity = 0.0
                if settings.idleBehaviour == .ambientGlow {
                    idleIntensity = settings.idleLevel * (0.6 + 0.4 * sin(t * 0.4 + Double(fx.id) * 0.5))
                    let c = fx.id % 2 == 0 ? RGB.brandGreen : RGB.brandMagenta
                    s.color = s.color.mix(c, idleLevelState)
                    s.hybridColor = idleLevelState > 0.5 ? HybridColor.nearest(to: c) : s.hybridColor
                    if fx.kind == .focusHybrid { s.frost = max(s.frost, 0.7 * idleLevelState); s.gobo = 0; s.prism = 0 }
                    s.zoom = lerp(s.zoom, 1, idleLevelState)
                }
                s.intensity = lerp(s.intensity, idleIntensity, idleLevelState)
                s.shutter = .open
                out[fx.id] = s
            }
        }

        // Operator overrides and master
        for fx in rig.fixtures {
            guard var s = out[fx.id] else { continue }
            if gap { s.intensity = 0 }
            if flashHeld { s.intensity = 1; s.color = s.color.mix(.white, 0.5) }
            s.intensity = clamp(s.intensity * settings.masterDimmer, 0, 1)
            if blackout { s.intensity = 0 }
            if !settings.useGobos { s.gobo = 0; s.staticGobo = 0 }
            out[fx.id] = s
        }

        st.tierName = mode == .audio ? ["Calm", "Groove", "High", "Peak"][tier] : st.modeName
        st.section = mode == .audio ? music.section : .groove
        st.lookSummary = look.summary
        st.paletteName = look.palette.name
        st.bpm = music.bpm
        st.beatInBar = Int(floor(beatInBar))
        st.bar = bar
        st.energy = mode == .audio ? smoothedEnergy : music.energy
        st.strobing = strobeWanted
        if gap { st.special = "Pre-drop gap" }
        else if impact != nil { st.special = "DROP!" }
        else if let p = buildProgress { st.special = "Build-up \(Int(p * 100))%" }
        else if idle { st.special = "Idle" }
        status = st
        lastStates = out
        return out
    }

    // MARK: - Director

    private func computeTier(energy e: Double, section: MusicSection, current: Int) -> Int {
        // Hysteresis so looks don't flip-flop at tier boundaries.
        let up: [Double] = [0.34, 0.62, 0.84]
        let down: [Double] = [0.26, 0.54, 0.76]
        var t = current
        while t < 3 && e > up[t] { t += 1 }
        while t > 0 && e < down[t - 1] { t -= 1 }
        switch section {
        case .drop: t = max(t, 2)
        case .peak: t = max(t, 2)
        case .breakdown: t = min(t, 1)
        case .ambient: t = min(t, 0)
        default: break
        }
        return t
    }

    private func handleSectionChange(from old: MusicSection, to new: MusicSection, beat: Double, bar: Int,
                                     music: MusicState, pool: LookPool, palettes: [Palette]) {
        phraseOriginBar = bar
        if new == .silence { return }
        if new == .drop {
            impactStartBeat = music.source == .track ? max(music.sectionStartBeat, beat - 0.25) : beat
            tier = max(tier, 3)
            look = evolve(look, pool: .peak, palettes: palettes, full: true, palette: true)
        } else if new == .build {
            return // the build-up is rendered as an overlay on the current look
        } else {
            look = evolve(look, pool: pool, palettes: palettes, full: true, palette: old == .breakdown || old == .silence || new == .breakdown)
        }
        barsSinceLook = 0
        barsSincePalette = 0
    }

    private func palettesForPolicy(calm: Bool) -> [Palette] {
        switch settings.colorPolicy {
        case .brandOnly: return Palette.brandPalettes
        case .brandMostly:
            // Brand palettes are listed multiple times so they are picked ~75% of the time.
            return Palette.brandPalettes + Palette.brandPalettes + Palette.brandPalettes + Palette.extraPalettes
        case .anything: return Palette.all
        }
    }

    private func pick<T: Equatable>(_ options: [T], avoiding current: T) -> T {
        guard !options.isEmpty else { return current }
        let filtered = options.count > 1 ? options.filter { $0 != current } : options
        let idx = Int(rng.unit() * Double(filtered.count)) % filtered.count
        return filtered[idx]
    }

    private func pickValue(_ options: [Double]) -> Double {
        guard !options.isEmpty else { return 1 }
        return options[Int(rng.unit() * Double(options.count)) % options.count]
    }

    private func makeLook(pool: LookPool, palettes: [Palette]) -> Look {
        var l = Look()
        l = evolve(l, pool: pool, palettes: palettes, full: true, palette: true)
        return l
    }

    /// Changes a look. A partial evolve changes only one or two aspects so the show feels continuous.
    private func evolve(_ l: Look, pool: LookPool, palettes: [Palette], full: Bool, palette: Bool) -> Look {
        var n = l
        n.floor = pool.floor
        n.moveSmoothing = pool.moveSmoothing
        n.colorFade = pool.colorFade
        n.l7Zoom = clamp(n.l7Zoom, pool.l7Zoom.lowerBound, pool.l7Zoom.upperBound)
        n.hybridZoom = clamp(n.hybridZoom, pool.hybridZoom.lowerBound, pool.hybridZoom.upperBound)
        if !pool.cycleBeats.contains(n.moveCycleBeats) { n.moveCycleBeats = pickValue(pool.cycleBeats) }
        if !pool.chaseRates.contains(n.chaseRate) { n.chaseRate = pickValue(pool.chaseRates) }
        if palette {
            let p = pick(palettes, avoiding: l.palette)
            n.palette = p
        }
        let aspects = full ? Set(0..<6) : Set([Int(rng.unit() * 6) % 6, Int(rng.unit() * 6) % 6])
        // Keep everything inside the pool, even the aspects not being changed.
        if full || !pool.l7Color.contains(n.l7Color) || aspects.contains(0) { n.l7Color = pick(pool.l7Color, avoiding: l.l7Color) }
        if full || !pool.l7Intensity.contains(n.l7Intensity) || aspects.contains(1) {
            n.l7Intensity = pick(pool.l7Intensity, avoiding: l.l7Intensity)
            n.chaseRate = pickValue(pool.chaseRates)
        }
        if full || !pool.l7Move.contains(n.l7Move) || aspects.contains(2) {
            n.l7Move = pick(pool.l7Move, avoiding: l.l7Move)
            n.moveCycleBeats = pickValue(pool.cycleBeats)
            n.l7Zoom = lerp(pool.l7Zoom.lowerBound, pool.l7Zoom.upperBound, rng.unit())
        }
        if full || !pool.hybridColor.contains(n.hybridColor) || aspects.contains(3) { n.hybridColor = pick(pool.hybridColor, avoiding: l.hybridColor) }
        if full || !pool.hybridBeam.contains(n.hybridBeam) || aspects.contains(4) {
            var beams = pool.hybridBeam
            if !settings.useGobos { beams = beams.filter { ![.goboSpin, .goboPrism, .shake].contains($0) } }
            if beams.isEmpty { beams = [.beam] }
            n.hybridBeam = pick(beams, avoiding: l.hybridBeam)
            n.gobo = Int(pickValue(pool.gobos.map(Double.init)))
            n.hybridZoom = lerp(pool.hybridZoom.lowerBound, pool.hybridZoom.upperBound, rng.unit())
        }
        if full || !pool.hybridIntensity.contains(n.hybridIntensity) || aspects.contains(5) {
            n.hybridIntensity = pick(pool.hybridIntensity, avoiding: l.hybridIntensity)
            n.hybridMove = pick(pool.hybridMove, avoiding: l.hybridMove)
        }
        if !pool.hybridMove.contains(n.hybridMove) { n.hybridMove = pick(pool.hybridMove, avoiding: l.hybridMove) }
        return n
    }

    private func applyBeam(_ beam: HybridBeam, to s: inout FixtureState, side: Int) {
        let dir = Double(side)
        switch beam {
        case .wash:
            s.frost = 0.65
        case .beam:
            break
        case .prism:
            s.prism = 1; s.prismRotation = 0.25 * dir
        case .goboSpin:
            s.gobo = look.gobo; s.goboRotation = 0.35 * dir
        case .goboPrism:
            s.gobo = look.gobo; s.goboRotation = 0.3 * dir; s.prism = 1; s.prismRotation = -0.2 * dir
        case .linearPrism:
            s.prism = 2; s.prismRotation = 0.15 * dir
        case .shake:
            s.gobo = look.gobo; s.goboShake = 0.6
        }
    }

    // MARK: - Smoothing

    private func smoothAim(_ id: Int, _ target: (Double, Double), dt: Double, tc: Double,
                           calibration: FixtureCalibration) -> (pan: Double, tilt: Double) {
        let safe = BeamGeometry.safeAim(pan: target.0, tilt: target.1, calibration: calibration)
        guard let cur = aimState[id] else { aimState[id] = safe; return safe }
        let p = smoothTowards(cur.pan, safe.pan, dt: dt, timeConstant: tc)
        let t = smoothTowards(cur.tilt, safe.tilt, dt: dt, timeConstant: tc)
        aimState[id] = (p, t)
        return (p, t)
    }

    private func smoothColor(_ id: Int, _ target: RGB, dt: Double, tc: Double) -> RGB {
        guard let cur = colorState[id] else { colorState[id] = target; return target }
        let a = tc <= 0 ? 1 : 1 - exp(-dt / tc)
        let c = cur.mix(target, a)
        colorState[id] = c
        return c
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
        // a synthetic kick on every beat so "kick" patterns also work in mood shows
        s.kickCount = Int(floor(s.beatPosition))
        return s
    }
}
