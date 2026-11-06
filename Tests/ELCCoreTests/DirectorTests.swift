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
