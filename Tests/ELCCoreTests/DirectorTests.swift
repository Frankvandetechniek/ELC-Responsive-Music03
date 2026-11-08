import XCTest
@testable import ELCCore

/// A simple analysed song: verse (groove) / chorus (peak) / verse / chorus at 124 BPM, 16 bars each.
struct SongTimeline {
    struct Part { let kind: MusicSection; let startBeat: Double; let energy: Double }
    let bpm = 124.0
    let parts: [Part] = [
        Part(kind: .groove, startBeat: 0, energy: 0.5),
        Part(kind: .peak, startBeat: 64, energy: 0.85),
        Part(kind: .groove, startBeat: 128, energy: 0.5),
        Part(kind: .peak, startBeat: 192, energy: 0.85),
    ]
    let endBeat = 256.0
    var style: MusicStyle = .pop

    func state(at t: Double) -> MusicState {
        var m = MusicState()
        m.source = .track; m.isSilent = false; m.timestamp = t; m.bpm = bpm
        m.beatPosition = t * bpm / 60
        m.tempoConfidence = 1
        m.trackProgress = m.beatPosition / endBeat
        let idx = parts.lastIndex { $0.startBeat <= m.beatPosition } ?? 0
        let p = parts[idx]
        m.section = p.kind; m.sectionStartBeat = p.startBeat; m.energy = p.energy; m.sectionEnergy = p.energy
        m.isFinalPeak = idx == parts.count - 1
        if idx + 1 < parts.count { m.nextSection = parts[idx + 1].kind; m.beatsToNextSection = parts[idx + 1].startBeat - m.beatPosition }
        var v = Vibe(); v.isReady = true; v.style = style; v.arousal = 0.7; v.valence = 0.7
        m.vibe = v
        return m
    }
}

final class DirectorTests: XCTestCase {
    let dt = 1.0 / 44

    func testLooksOnlyChangeAtSectionBoundariesAndChorusIsReused() {
        let song = SongTimeline()
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 31)
        e.mode = .audio
        var t = 0.0
        var lastChanges = e.cueChanges
        var changeBeats: [Double] = []
        var chorus1: Look? = nil, chorus2: Look? = nil
        var sawFinalPeak = false
        while t * song.bpm / 60 < song.endBeat - 1 {
            t += dt
            let m = song.state(at: t)
            _ = e.tick(music: m, now: t, dt: dt)
            if e.cueChanges != lastChanges { changeBeats.append(m.beatPosition); lastChanges = e.cueChanges }
            if abs(m.beatPosition - 100) < 0.05 { chorus1 = e.look }
            if abs(m.beatPosition - 230) < 0.05 { chorus2 = e.look }
            if e.status.special == "Final peak" { sawFinalPeak = true }
        }
        // Every look change lands on (or within a beat after) a section start — never mid-section.
        let boundaries: [Double] = [0, 64, 128, 192]
        for b in changeBeats {
            XCTAssertTrue(boundaries.contains { b >= $0 - 0.05 && b < $0 + 1.05 }, "look changed mid-section at beat \(b) (\(changeBeats))")
        }
        XCTAssertGreaterThanOrEqual(changeBeats.count, 3)
        // The second chorus re-uses the first chorus look (and gets the final-peak lift).
        let c1 = try! XCTUnwrap(chorus1), c2 = try! XCTUnwrap(chorus2)
        XCTAssertEqual(c1.palette, c2.palette)
        XCTAssertEqual(c1.l7Intensity, c2.l7Intensity)
        XCTAssertEqual(c1.hybridBeam, c2.hybridBeam)
        XCTAssertEqual(c1.hybridMove, c2.hybridMove)
        XCTAssertFalse(c1.lift)
        XCTAssertTrue(c2.lift)
        XCTAssertTrue(sawFinalPeak)
    }

    /// Same song lit as EDM vs ballad: the EDM chorus must be clearly more dynamic.
    func testEDMIsMoreDynamicThanBallad() {
        func dynamics(_ style: MusicStyle) -> (intensityChange: Double, moveSpeed: Double) {
            var song = SongTimeline()
            song.style = style
            let e = ShowEngine(rig: Rig.elcDefault(), seed: 4)
            e.mode = .audio
            e.settings.styleOverride = style
            var t = 0.0
            var prev: [Int: FixtureState] = [:]
            var dI = 0.0, dP = 0.0, n = 0.0
            while t * song.bpm / 60 < 120 {
                t += dt
                let m = song.state(at: t)
                let out = e.tick(music: m, now: t, dt: dt)
                if m.beatPosition > 72 {       // inside the first chorus
                    for (id, s) in out {
                        if let p = prev[id] { dI += abs(s.intensity - p.intensity); dP += abs(s.pan - p.pan) + abs(s.tilt - p.tilt) }
                    }
                    n += 1
                }
                prev = out
            }
            return (dI / n / dt, dP / n / dt)
        }
        let edm = dynamics(.edm), ballad = dynamics(.ballad)
        XCTAssertGreaterThan(edm.intensityChange, ballad.intensityChange * 2, "edm \(edm) ballad \(ballad)")
        XCTAssertGreaterThan(edm.moveSpeed, ballad.moveSpeed * 1.5, "edm \(edm) ballad \(ballad)")
    }

    func testSteadyLiveGrooveDoesNotChangeLooksRandomly() {
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 9)
        e.mode = .audio
        var music = NoisyLiveMusic()
        music.flickerSections = false
        music.energyNoise = 0.1
        var t = 0.0
        for _ in 0..<Int(44 * 90) { t += dt; _ = e.tick(music: music.state(at: t), now: t, dt: dt) }
        XCTAssertLessThanOrEqual(e.cueChanges, 2, "a steady groove should keep its look")
    }

    func testDropLookIsReusedAndFeaturedGroupGivesContrast() {
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 12)
        e.mode = .audio
        e.settings.styleOverride = .edm
        // Low-energy section: one group carries the look, the other is clearly dimmer.
        var t = 0.0
        var m = MusicState()
        m.source = .track; m.isSilent = false; m.bpm = 128; m.tempoConfidence = 1; m.trackProgress = 0.1
        m.section = .breakdown; m.sectionEnergy = 0.2; m.energy = 0.2
        var out: [Int: FixtureState] = [:]
        for _ in 0..<(44 * 10) { t += dt; m.timestamp = t; m.beatPosition = t * 128 / 60; out = e.tick(music: m, now: t, dt: dt) }
        XCTAssertNotEqual(e.look.featured, .both)
        let l7 = Rig.elcDefault().l7s.map { out[$0.id]!.intensity }.reduce(0, +) / 6
        let hy = Rig.elcDefault().hybrids.map { out[$0.id]!.intensity }.reduce(0, +) / 6
        if e.look.featured == .l7 { XCTAssertGreaterThan(l7, hy * 1.4) } else { XCTAssertGreaterThan(hy, l7 * 1.4) }
    }
}

final class PixelTests: XCTestCase {
    let dt = 1.0 / 44

    /// "Effects are a continuation of the look": never a chase across the bars *and* a moving pixel effect.
    func testOnlyOneMovingLayerOnTheL7s() {
        let moving: Set<IntensityPattern> = [.chase, .bounce, .wave, .breathe, .snareChase, .centerOut]
        var sawMovingPixels = false
        for seed in 1...12 {
            for style in [MusicStyle.edm, .pop, .house] {
                var song = SongTimeline(); song.style = style
                let e = ShowEngine(rig: Rig.elcDefault(), seed: UInt64(seed))
                e.mode = .audio
                e.settings.styleOverride = style
                var t = 0.0
                while t * song.bpm / 60 < 70 {
                    t += dt
                    _ = e.tick(music: song.state(at: t), now: t, dt: dt)
                    if moving.contains(e.look.l7Intensity) { XCTAssertFalse(e.look.l7Pixels.isMoving, "\(e.look.summary) + \(e.look.l7Pixels)") }
                    if e.look.l7Pixels.isMoving { sawMovingPixels = true }
                }
            }
        }
        XCTAssertTrue(sawMovingPixels, "pixel effects are never used")
    }

    /// During a build-up the L7 bars fill from their centre outwards.
    func testBuildUpChargesBarsFromCentre() {
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 2)
        e.mode = .audio
        e.settings.styleOverride = .edm
        var t = 0.0
        var early: [RGB]? = nil, late: [RGB]? = nil
        let l7 = Rig.elcDefault().l7s[2].id
        while t < 45 {
            t += dt
            var m = MusicState()
            m.source = .track; m.isSilent = false; m.timestamp = t; m.bpm = 128; m.beatPosition = t * 128 / 60
            m.trackProgress = t / 60; m.tempoConfidence = 1
            if m.beatPosition < 32 { m.section = .groove; m.nextSection = .build; m.beatsToNextSection = 32 - m.beatPosition; m.sectionEnergy = 0.5 }
            else { m.section = .build; m.sectionStartBeat = 32; m.nextSection = .drop; m.beatsToNextSection = 96 - m.beatPosition; m.sectionEnergy = 0.5 }
            let out = e.tick(music: m, now: t, dt: dt)
            if early == nil && m.beatPosition >= 70 { early = out[l7]!.pixels }
            if late == nil && m.beatPosition >= 93 { late = out[l7]!.pixels }
        }
        func bright(_ c: RGB) -> Double { max(c.r, c.g, c.b) }
        let a = try! XCTUnwrap(early), b = try! XCTUnwrap(late)
        XCTAssertGreaterThan(bright(a[3]), bright(a[0]) * 2, "centre lit before the edges")
        XCTAssertGreaterThan(bright(b[0]), bright(a[0]) * 2, "edges fill up as the build progresses")
    }

    func testPixelsReachTheDMXOutput() {
        var s = FixtureState()
        s.intensity = 1
        s.pixels = PatternMath.l7Pixels(.split, palette: .brand, colour: .white, bar: 0, bars: 6, beat: 0, barBeat: 0, cycle: 8)
        let ch = FixtureEncoder.encode(s, patch: Rig.elcDefault().l7s[0])
        // pixel 1 = brand green (G high, R low), pixel 7 = brand magenta (R high, G low)
        XCTAssertGreaterThan(ch[5], 200); XCTAssertLessThan(ch[4], 30)
        XCTAssertGreaterThan(ch[28], 200); XCTAssertLessThan(ch[29], 30)
    }
}
