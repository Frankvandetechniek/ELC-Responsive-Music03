import XCTest
@testable import ELCCore

/// Pop-style beat: kick on 1 & 3, snare on 2 & 4, closed hats on 8ths, a bass note and a pad.
func synthPopBeat(bpm: Double, seconds: Double, sr: Double = 22050, extraSnareSlot: Int? = nil) -> [Float] {
    let n = Int(seconds * sr)
    var out = [Float](repeating: 0, count: n)
    let beat = 60 / bpm
    var rng = SeededRandom(seed: 5)
    for i in 0..<n {
        let t = Double(i) / sr
        let barPos = fmodPositive(t, beat * 4) / beat          // 0..<4
        let beatIdx = Int(floor(barPos))
        let ph = (barPos - Double(beatIdx)) * beat               // seconds since beat
        var v = 0.0
        if beatIdx == 0 || beatIdx == 2 {                         // kick
            v += 0.8 * exp(-ph * 18) * sin(2 * .pi * (50 + 80 * exp(-ph * 30)) * ph)
        }
        func snare(_ dt: Double) -> Double {
            guard dt >= 0 && dt < 0.25 else { return 0 }
            return 0.45 * exp(-dt * 22) * (rng.unit() * 2 - 1) + 0.3 * exp(-dt * 30) * sin(2 * .pi * 190 * dt)
        }
        if beatIdx == 1 || beatIdx == 3 { v += snare(ph) }        // snare on 2 & 4
        if let s = extraSnareSlot {
            let slotT = Double(s) * beat / 4
            v += snare(fmodPositive(t, beat * 4) - slotT)
        }
        let eighth = fmodPositive(t, beat / 2)                     // hats
        v += 0.06 * exp(-eighth * 90) * (rng.unit() * 2 - 1)
        v += 0.12 * sin(2 * .pi * 110 * t) + 0.05 * sin(2 * .pi * 440 * t)
        out[i] = Float(v)
    }
    return out
}

final class GrooveTests: XCTestCase {
    func testTrackAnalysisLearnsBackbeatSnare() {
        let a = TrackAnalyzer.analyze(samples: synthPopBeat(bpm: 112, seconds: 30), sampleRate: 22050)
        XCTAssertEqual(a.bpm, 112, accuracy: 1.5)
        let steps = SnareSteps.from(pattern: a.snarePattern, clarity: a.snareClarity)
        XCTAssertTrue(steps.learned, "pattern \(a.snarePattern.map { String(format: "%.2f", $0) }) clarity \(a.snareClarity)")
        XCTAssertEqual(steps.slots.count, 2)
        // Two hits half a bar apart, on beats (not between them).
        XCTAssertEqual(steps.slots[1] - steps.slots[0], 8)
        XCTAssertEqual(steps.slots[0] % 4, 0)
        // With the bar aligned, that's beats 2 and 4.
        XCTAssertEqual(steps.slots, [4, 12], "downbeat offset \(a.downbeatOffset)")
    }

    func testLiveAnalyzerLearnsSnareGroove() {
        let sr = 22050.0
        let audio = synthPopBeat(bpm: 120, seconds: 24, sr: sr, extraSnareSlot: 14)   // extra snare on the "4-and"
        let la = LiveAnalyzer(sampleRate: sr)
        var t = 0.0, i = 0
        while i < audio.count {
            let n = min(1024, audio.count - i)
            t += Double(n) / sr
            la.process(Array(audio[i..<(i + n)]), now: t)
            i += n
        }
        let s = la.state
        let steps = SnareSteps.from(pattern: s.snarePattern, clarity: s.snareClarity)
        XCTAssertTrue(steps.learned, "pattern \(s.snarePattern.map { String(format: "%.2f", $0) })")
        XCTAssertGreaterThanOrEqual(steps.slots.count, 2)
        // relative spacing is independent of the bar alignment: 4, 12 and 14 (14 is 2 after 12)
        let rel = Set(steps.slots.map { (($0 - steps.slots[0]) % 16 + 16) % 16 })
        XCTAssertTrue(rel.contains(8) || rel.contains(10) || rel.contains(6), "slots \(steps.slots)")
    }

    func testSnareChaseStepsExactlyOnTheSnare() {
        let steps = SnareSteps.backbeat   // snare on beats 2 and 4
        func level(_ fixture: Int, bar: Int, barBeat: Double) -> Double {
            PatternMath.intensity(.snareChase, beat: Double(bar) * 4 + barBeat, barBeat: barBeat, bar: bar,
                                  index: fixture, count: 6, rate: 1, cycle: 8, x: 0, snare: steps)
        }
        // On beat 2 of bar 10 a new step starts: step = 10*2 + 1 - 1 = 20 → fixture 20 % 6 = 2 is at full.
        XCTAssertEqual(level(2, bar: 10, barBeat: 1.0), 1, accuracy: 1e-9)
        // Just before it (on the "1-and"), fixture 2 is dark and the previous fixture (1) is fading.
        XCTAssertEqual(level(2, bar: 10, barBeat: 0.9), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(level(1, bar: 10, barBeat: 0.9), 0)
        XCTAssertLessThan(level(1, bar: 10, barBeat: 0.9), 0.6)
        // On beat 4 the chase moves on to fixture 3.
        XCTAssertEqual(level(3, bar: 10, barBeat: 3.0), 1, accuracy: 1e-9)
        XCTAssertLessThan(level(2, bar: 10, barBeat: 3.0), level(3, bar: 10, barBeat: 3.0))
        // snareHit: everything bumps on the snare and is low just before the next one.
        let hitOn = PatternMath.intensity(.snareHit, beat: 41, barBeat: 1, bar: 10, index: 0, count: 6, rate: 1, cycle: 8, x: 0, snare: steps)
        let hitBefore = PatternMath.intensity(.snareHit, beat: 42.95, barBeat: 2.95, bar: 10, index: 0, count: 6, rate: 1, cycle: 8, x: 0, snare: steps)
        XCTAssertEqual(hitOn, 1, accuracy: 1e-9)
        XCTAssertLessThan(hitBefore, 0.05)
    }

    func testPopEngineUsesSnarePatterns() {
        // With a clear snare groove and the pop style, most cues should follow the snare on the L7s.
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 21)
        e.mode = .audio
        e.settings.styleOverride = .pop
        var t = 0.0
        var snareCues = Set<String>()
        var cues = Set<String>()
        var learned = [Double](repeating: 0.05, count: 16); learned[4] = 1; learned[12] = 0.95
        for _ in 0..<(44 * 240) {
            t += 1.0 / 44
            var m = MusicState()
            m.source = .live; m.isSilent = false; m.timestamp = t; m.bpm = 120; m.beatPosition = t * 2
            m.energy = 0.6; m.section = .groove; m.tempoConfidence = 0.9
            m.snarePattern = learned; m.snareClarity = 0.9
            _ = e.tick(music: m, now: t, dt: 1.0 / 44)
            cues.insert(e.look.summary)
            if e.look.l7Intensity.isSnare { snareCues.insert(e.look.summary) }
            XCTAssertEqual(e.look.snare.slots, [4, 12])
        }
        XCTAssertGreaterThan(cues.count, 3)
        XCTAssertGreaterThanOrEqual(Double(snareCues.count) / Double(cues.count), 0.3, "\(snareCues.count)/\(cues.count)")
    }
}
