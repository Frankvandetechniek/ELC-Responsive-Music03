import XCTest
@testable import ELCCore

/// Live-like music state with realistic analyser noise: jittery beat phase, noisy energy,
/// flickering section guesses and kicks on every beat.
struct NoisyLiveMusic {
    var rng = SeededRandom(seed: 99)
    var bpm = 128.0
    var energyBase = 0.6
    var energyNoise = 0.3
    var flickerSections = true

    mutating func state(at t: Double) -> MusicState {
        var m = MusicState()
        m.source = .live
        m.isSilent = false
        m.timestamp = t
        m.bpm = bpm + (rng.unit() - 0.5) * 2
        m.beatPosition = t * bpm / 60 + (rng.unit() - 0.5) * 0.1
        m.energy = clamp(energyBase + (rng.unit() - 0.5) * 2 * energyNoise, 0, 1)
        m.kickCount = Int(t * bpm / 60)
        m.section = flickerSections ? (rng.unit() < 0.5 ? .groove : .peak) : .groove
        m.tempoConfidence = 0.8
        return m
    }
}

final class EngineTests: XCTestCase {
    let dt = 1.0 / 44

    func testMoodShowsProduceSafeOutput() {
        let rig = Rig.elcDefault()
        for mood in MoodShow.all {
            let e = ShowEngine(rig: rig, seed: 1)
            e.mode = .mood(mood.id)
            var t = 100.0
            var maxI = 0.0
            for _ in 0..<(44 * 40) {
                t += dt
                let out = e.tick(music: MusicState(), now: t, dt: dt)
                XCTAssertEqual(out.count, 12)
                for fx in rig.fixtures {
                    let s = out[fx.id]!
                    maxI = max(maxI, s.intensity)
                    XCTAssertGreaterThanOrEqual(s.tilt, -fx.calibration.backLimitDeg - 1e-6, "\(mood.name) \(fx.name)")
                    let fwd = sin(degToRad(s.tilt)) * cos(degToRad(s.pan))
                    XCTAssertGreaterThanOrEqual(fwd, -sin(degToRad(fx.calibration.backLimitDeg)) - 1e-6)
                    if !mood.allowsStrobe { XCTAssertEqual(s.shutter, .open, "\(mood.name) strobes") }
                }
            }
            XCTAssertGreaterThan(maxI, 0.3, "\(mood.name) too dark")
        }
    }

    /// The main complaint: lights must not visualise loudness. Same music timing, wildly
    /// different (noisy) loudness → identical lighting.
    func testIntensityDoesNotFollowLoudness() {
        let rig = Rig.elcDefault()
        func run(noise: Double) -> [[Double]] {
            let e = ShowEngine(rig: rig, seed: 7)
            e.mode = .audio
            var music = NoisyLiveMusic()
            music.energyNoise = noise
            music.flickerSections = false
            var frames: [[Double]] = []
            var t = 0.0
            for _ in 0..<(44 * 30) {
                t += dt
                var m = music.state(at: t)
                m.beatPosition = t * 128 / 60          // identical timing in both runs
                m.bpm = 128
                let out = e.tick(music: m, now: t, dt: dt)
                frames.append(rig.fixtures.map { out[$0.id]!.intensity })
            }
            return frames
        }
        let calm = run(noise: 0)
        let noisy = run(noise: 0.08)   // loudness wobble within one energy level
        var maxDiff = 0.0
        for (a, b) in zip(calm, noisy) { for (x, y) in zip(a, b) { maxDiff = max(maxDiff, abs(x - y)) } }
        XCTAssertLessThan(maxDiff, 0.02, "intensity follows loudness")
    }

    /// Noisy live analysis must still give a calm, professional show: few cue changes,
    /// limited speeds, no intensity flicker.
    func testNoisyLiveInputIsNotTwitchy() {
        let rig = Rig.elcDefault()
        let e = ShowEngine(rig: rig, seed: 3)
        e.mode = .audio
        var music = NoisyLiveMusic()
        var t = 0.0
        var prev: [Int: FixtureState] = [:]
        var maxPanSpeed = 0.0
        var reversals = 0
        var lastDir: [Int: Double] = [:]
        var lastBar = Int.min
        let seconds = 120.0
        for _ in 0..<Int(44 * seconds) {
            t += dt
            let out = e.tick(music: music.state(at: t), now: t, dt: dt)
            XCTAssertGreaterThanOrEqual(e.status.bar, lastBar == Int.min ? e.status.bar : lastBar, "clock ran backwards")
            lastBar = e.status.bar
            for fx in rig.fixtures {
                let s = out[fx.id]!
                if let p = prev[fx.id] {
                    maxPanSpeed = max(maxPanSpeed, abs(s.pan - p.pan) / dt, abs(s.tilt - p.tilt) / dt)
                    let d = s.intensity - p.intensity
                    if abs(d) > 0.01 {
                        if let ld = lastDir[fx.id], ld * d < 0 { reversals += 1 }
                        lastDir[fx.id] = d
                    }
                }
            }
            prev = out
        }
        // 128 BPM, 8–16 bar phrases → a cue every 15–30 s; allow some slack for level changes.
        XCTAssertLessThanOrEqual(e.cueChanges, Int(seconds / 15) + 3, "too many cue changes: \(e.cueChanges)")
        XCTAssertLessThanOrEqual(maxPanSpeed, 141, "moves too fast")
        // Intensity direction changes per fixture per second (beat pulses allowed: ≤ ~2 per beat at 128 BPM)
        let perFixturePerSecond = Double(reversals) / Double(rig.fixtures.count) / seconds
        XCTAssertLessThan(perFixturePerSecond, 4.5, "intensity flicker")
    }

    func testPauseFreezesShow() {
        let rig = Rig.elcDefault()
        let e = ShowEngine(rig: rig, seed: 5)
        e.mode = .mood(MoodShow.club.id)
        var t = 0.0
        for _ in 0..<(44 * 10) { t += dt; _ = e.tick(music: MusicState(), now: t, dt: dt) }
        e.paused = true
        for _ in 0..<(44 * 4) { t += dt; _ = e.tick(music: MusicState(), now: t, dt: dt) }  // settle
        let a = e.tick(music: MusicState(), now: t + dt, dt: dt)
        for _ in 0..<(44 * 5) { t += dt; _ = e.tick(music: MusicState(), now: t, dt: dt) }
        let b = e.tick(music: MusicState(), now: t + dt, dt: dt)
        for fx in rig.fixtures {
            XCTAssertEqual(a[fx.id]!.intensity, b[fx.id]!.intensity, accuracy: 1e-3)
            XCTAssertEqual(a[fx.id]!.pan, b[fx.id]!.pan, accuracy: 0.05)
            XCTAssertEqual(a[fx.id]!.tilt, b[fx.id]!.tilt, accuracy: 0.05)
        }
        XCTAssertEqual(e.status.special, "Paused")
        // Unpause: show continues moving.
        e.paused = false
        var moved = false
        let before = e.tick(music: MusicState(), now: t + 2 * dt, dt: dt)
        for _ in 0..<(44 * 6) { t += dt; let o = e.tick(music: MusicState(), now: t + 2 * dt, dt: dt)
            if rig.fixtures.contains(where: { abs(o[$0.id]!.pan - before[$0.id]!.pan) > 1 || abs(o[$0.id]!.tilt - before[$0.id]!.tilt) > 1 }) { moved = true } }
        XCTAssertTrue(moved)
    }

    func testStaticLookToggle() {
        let rig = Rig.elcDefault()
        let e = ShowEngine(rig: rig, seed: 5)
        e.mode = .audio
        var music = NoisyLiveMusic()
        var t = 0.0
        for _ in 0..<(44 * 10) { t += dt; _ = e.tick(music: music.state(at: t), now: t, dt: dt) }
        e.staticLook = true
        var out: [Int: FixtureState] = [:]
        for _ in 0..<(44 * 8) { t += dt; out = e.tick(music: music.state(at: t), now: t, dt: dt) }
        let target = e.makeStaticFrame()
        for fx in rig.fixtures {
            let s = out[fx.id]!, g = target[fx.id]!
            XCTAssertEqual(s.intensity, g.intensity, accuracy: 0.02, fx.name)
            XCTAssertEqual(s.pan, g.pan, accuracy: 1, fx.name)
            XCTAssertEqual(s.tilt, g.tilt, accuracy: 1, fx.name)
            XCTAssertEqual(s.shutter, .open)
            if fx.kind == .focusHybrid { XCTAssertEqual(s.hybridColor, g.hybridColor) }
        }
        XCTAssertEqual(e.status.special, "Static look")
        e.staticLook = false
        for _ in 0..<(44 * 6) { t += dt; out = e.tick(music: music.state(at: t), now: t, dt: dt) }
        XCTAssertNotEqual(e.status.special, "Static look")
        XCTAssertTrue(rig.fixtures.contains { abs(out[$0.id]!.pan - target[$0.id]!.pan) > 2 || abs(out[$0.id]!.tilt - target[$0.id]!.tilt) > 2 })
    }

    func testTrackDropGetsGapAndImpact() {
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 2)
        e.mode = .audio
        let bpm = 128.0
        let dropBeat = 64.0
        var sawGap = false, sawDrop = false, sawBuild = false
        var t = 0.0
        while t < 45 {
            t += dt
            var m = MusicState()
            m.source = .track
            m.isSilent = false
            m.timestamp = t
            m.bpm = bpm
            m.beatPosition = t * bpm / 60
            m.trackProgress = t / 60
            m.tempoConfidence = 1
            var v = Vibe(); v.isReady = true; v.style = .edm; v.arousal = 0.8; v.valence = 0.7
            m.vibe = v
            if m.beatPosition < 32 { m.section = .groove; m.energy = 0.6; m.nextSection = .build; m.beatsToNextSection = 32 - m.beatPosition }
            else if m.beatPosition < dropBeat { m.section = .build; m.sectionStartBeat = 32; m.energy = 0.5
                m.nextSection = .drop; m.beatsToNextSection = dropBeat - m.beatPosition }
            else { m.section = .drop; m.sectionStartBeat = dropBeat; m.energy = 0.95 }
            _ = e.tick(music: m, now: t, dt: dt)
            if e.status.special.hasPrefix("Build-up") { sawBuild = true }
            if e.status.special == "Pre-drop gap" { sawGap = true }
            if e.status.special == "DROP!" { sawDrop = true }
        }
        XCTAssertTrue(sawBuild)
        XCTAssertTrue(sawGap)
        XCTAssertTrue(sawDrop)
        XCTAssertEqual(e.status.styleName, MusicStyle.edm.rawValue)
    }

    func testSilenceGoesIdleAndBlackoutWorks() {
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 4)
        e.mode = .audio
        var music = NoisyLiveMusic()
        var t = 0.0
        for _ in 0..<(44 * 10) { t += dt; _ = e.tick(music: music.state(at: t), now: t, dt: dt) }
        var m = music.state(at: t)
        m.isSilent = true
        m.section = .silence
        var out: [Int: FixtureState] = [:]
        for _ in 0..<(44 * 10) { t += dt; m.timestamp = t; out = e.tick(music: m, now: t, dt: dt) }
        XCTAssertLessThan(out.values.map { $0.intensity }.max()!, 0.2)
        e.blackout = true
        for _ in 0..<10 { t += dt; out = e.tick(music: m, now: t, dt: dt) }
        XCTAssertEqual(out.values.map { $0.intensity }.max()!, 0, accuracy: 1e-9)
    }

    func testStrobeDisabledNeverStrobes() {
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 8)
        e.settings.strobeEnabled = false
        e.mode = .mood(MoodShow.partyPeak.id)
        var t = 0.0
        for _ in 0..<(44 * 40) {
            t += dt
            for s in e.tick(music: MusicState(), now: t, dt: dt).values { XCTAssertEqual(s.shutter, .open) }
        }
    }
}

// MARK: - Vibe

/// Simple synthetic music for vibe tests.
func synthMusic(bpm: Double, seconds: Double, sr: Double = 22050, kickEveryBeat: Bool, hats: Bool,
                chord: [Double], minorThird: Bool = false, percussive: Bool = true) -> [Float] {
    let n = Int(seconds * sr)
    var out = [Float](repeating: 0, count: n)
    let period = 60 / bpm
    var rng = SeededRandom(seed: 11)
    for i in 0..<n {
        let t = Double(i) / sr
        let beatPhase = fmodPositive(t, period)
        let beatIdx = Int(t / period)
        var v = 0.0
        if percussive {
            if kickEveryBeat || beatIdx % 2 == 0 {
                let env = exp(-beatPhase * 18)
                v += 0.7 * env * sin(2 * .pi * (50 + 80 * exp(-beatPhase * 30)) * beatPhase)
            }
            if hats {
                let off = fmodPositive(t - period / 2, period)
                v += 0.12 * exp(-off * 60) * (rng.unit() * 2 - 1)
            }
        }
        // sustained chord
        for f in chord { v += 0.08 * sin(2 * .pi * f * t) + 0.03 * sin(2 * .pi * 2 * f * t) }
        out[i] = Float(v)
    }
    return out
}

final class VibeTests: XCTestCase {
    // C major: C4 E4 G4 ; A minor: A3 C4 E4
    let cMajor: [Double] = [261.63, 329.63, 392.0, 130.81]
    let aMinor: [Double] = [220.0, 261.63, 329.63, 110.0]

    func testKeyDetection() {
        let a = TrackAnalyzer.analyze(samples: synthMusic(bpm: 120, seconds: 20, kickEveryBeat: true, hats: false, chord: cMajor), sampleRate: 22050)
        XCTAssertEqual(a.vibe.key, "C major")
        XCTAssertGreaterThan(a.vibeFeatures.majorness, 0)
        let b = TrackAnalyzer.analyze(samples: synthMusic(bpm: 120, seconds: 20, kickEveryBeat: true, hats: false, chord: aMinor), sampleRate: 22050)
        XCTAssertEqual(b.vibe.key, "A minor")
        XCTAssertLessThan(b.vibeFeatures.majorness, 0)
        XCTAssertGreaterThan(a.vibe.valence, b.vibe.valence)
    }

    func testClubTrackVsAmbient() {
        let club = TrackAnalyzer.analyze(samples: synthMusic(bpm: 124, seconds: 30, kickEveryBeat: true, hats: true, chord: aMinor), sampleRate: 22050)
        XCTAssertGreaterThan(club.vibeFeatures.fourOnFloor, 0.5)
        XCTAssertTrue([.house, .edm].contains(club.vibe.style), "club detected as \(club.vibe.style)")

        let ambient = TrackAnalyzer.analyze(samples: synthMusic(bpm: 70, seconds: 30, kickEveryBeat: false, hats: false,
                                                               chord: cMajor, percussive: false), sampleRate: 22050)
        XCTAssertTrue([.ambient, .ballad].contains(ambient.vibe.style), "ambient detected as \(ambient.vibe.style)")
        XCTAssertGreaterThan(club.vibe.arousal, ambient.vibe.arousal)
    }

    func testSoundEvidenceSteersStyle() {
        var f = VibeFeatures()
        f.bpm = 120; f.pulseClarity = 0.6; f.onsetRate = 4; f.backbeat = 0.7; f.brightness = 0.4
        f.bassShare = 0.3; f.percussiveness = 0.5; f.majorness = 0.2; f.tonalClarity = 0.6
        f.evidence = [SoundEvidence.electricGuitar.rawValue: 0.9, SoundEvidence.drums.rawValue: 0.8]
        XCTAssertEqual(VibeModel.infer(f).style, .rock)
        f.evidence = [SoundEvidence.rap.rawValue: 0.9]; f.bpm = 90; f.bassShare = 0.5
        XCTAssertEqual(VibeModel.infer(f).style, .hipHop)
        let ev = SoundEvidence.evidence(from: ["singing": 0.7, "electric_guitar": 0.4, "dog_bark": 0.9])
        XCTAssertEqual(ev[.vocals], 0.7)
        XCTAssertEqual(ev[.electricGuitar], 0.4)
    }

    func testLiveAnalyzerProducesVibe() {
        let sr = 22050.0
        let audio = synthMusic(bpm: 126, seconds: 20, sr: sr, kickEveryBeat: true, hats: true, chord: aMinor)
        let la = LiveAnalyzer(sampleRate: sr)
        var t = 0.0, i = 0
        while i < audio.count {
            let n = min(1024, audio.count - i)
            t += Double(n) / sr
            la.process(Array(audio[i..<(i + n)]), now: t)
            i += n
        }
        XCTAssertTrue(la.state.vibe.isReady)
        XCTAssertFalse(la.state.vibe.key.isEmpty)
    }
}
