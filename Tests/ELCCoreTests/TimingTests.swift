import XCTest
@testable import ELCCore

/// Timing regression tests: beats must land on the kick, not after it.
final class TimingTests: XCTestCase {
    /// Live input: measured lag of the beat clock behind the real kicks (ms) and its jitter.
    func liveLag(bpm: Double, sr: Double) -> (lag: Double, jitter: Double, bpm: Double) {
        let period = 60 / bpm
        let audio = synthTrack(bpm: bpm, seconds: 35, sr: sr)
        let la = LiveAnalyzer(sampleRate: sr)
        la.config.latencyCompensation = 0
        var t = 0.0, i = 0
        var lags: [Double] = []
        while i < audio.count {
            let n = min(1024, audio.count - i); t += Double(n) / sr
            la.process(Array(audio[i..<(i + n)]), now: t); i += n
            if t > 20 {
                var o = fmodPositive(la.state.beat(at: t), 1) - fmodPositive(t / period, 1)
                if o > 0.5 { o -= 1 }; if o < -0.5 { o += 1 }
                lags.append(-o * period * 1000)
            }
        }
        let m = lags.reduce(0, +) / Double(lags.count)
        let sd = (lags.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(lags.count)).squareRoot()
        return (m, sd, la.state.bpm)
    }

    func testLiveBeatIsOnTheKick() {
        for sr in [44100.0, 48000.0] {
            for bpm in [122.0, 126.3, 128.0, 140.0] {
                let r = liveLag(bpm: bpm, sr: sr)
                XCTAssertEqual(r.bpm, bpm, accuracy: 1, "sr \(sr) bpm \(bpm)")
                XCTAssertLessThan(abs(r.lag), 12, "live beat \(r.lag) ms off at \(bpm) BPM / \(sr) Hz")
                XCTAssertLessThan(r.jitter, 8)
            }
        }
    }

    func testSetlistBeatGridIsOnTheKick() {
        for sr in [22050.0, 24000.0] {
            for bpm in [124.0, 150.0] {
                let period = 60 / bpm
                let a = TrackAnalyzer.analyze(samples: synthTrack(bpm: bpm, seconds: 30, sr: sr), sampleRate: sr)
                let offs = a.beatTimes.dropFirst(8).dropLast(4).map { t -> Double in
                    var o = fmodPositive(t, period); if o > period / 2 { o -= period }; return o }
                let mean = offs.reduce(0, +) / Double(offs.count) * 1000
                XCTAssertLessThan(abs(mean), 6, "beat grid \(mean) ms off at \(bpm) BPM")
            }
        }
    }
}

final class DropPrecisionTests: XCTestCase {
    /// Drops that don't sit on a 4-bar phrase line (e.g. after a 7-bar breakdown) must still be exact.
    func testDropBoundaryIsBeatExact() {
        let sr = 22050.0
        for (bpm, breakStart, dropAt) in [(126.0, 32.0, 60.0), (128.0, 36.0, 68.0), (140.0, 40.0, 72.0)] {
            let beat = 60 / bpm
            let audio = synthTrack(bpm: bpm, seconds: beat * (dropAt + 48), sr: sr,
                                   breakdown: (beat * breakStart)...(beat * dropAt - 0.01))
            let a = TrackAnalyzer.analyze(samples: audio, sampleRate: sr)
            guard let drop = a.sections.first(where: { $0.kind == .drop }) else {
                XCTFail("no drop found at \(bpm): \(a.sections.map { "\($0.kind.rawValue)@\($0.startBeat)" })"); continue
            }
            XCTAssertEqual(drop.startTime, beat * dropAt, accuracy: beat * 0.25,
                           "drop at beat \(drop.startTime / beat), expected \(dropAt) (\(bpm) BPM)")
            // and it lands on "the 1"
            XCTAssertEqual((drop.startBeat - a.downbeatOffset) % 4, 0, "bpm \(bpm) drop idx \(drop.startBeat) downbeat \(a.downbeatOffset) first beat t=\(a.beatTimes[0]) sections \(a.sections.map { "\($0.kind.rawValue)@\($0.startBeat)" })")
        }
    }
}

final class LiveDropTests: XCTestCase {
    func testLiveDropIsDetectedOnTheBeatAndQuickly() {
        let sr = 44100.0
        for (bpm, dropAt) in [(126.0, 64.0), (128.0, 72.0)] {
            let period = 60 / bpm
            let audio = synthTrack(bpm: bpm, seconds: period * (dropAt + 24), sr: sr,
                                   breakdown: (period * (dropAt - 24))...(period * dropAt - 0.01))
            let la = LiveAnalyzer(sampleRate: sr)
            la.config.latencyCompensation = 0
            var t = 0.0, i = 0
            var detectedAt: Double? = nil, dropTime: Double? = nil
            while i < audio.count {
                let n = min(512, audio.count - i); t += Double(n) / sr
                la.process(Array(audio[i..<(i + n)]), now: t); i += n
                let s = la.state
                if detectedAt == nil && s.dropCount > 0 {
                    detectedAt = t
                    dropTime = t - (s.beat(at: t) - s.dropBeat) * period   // beat → seconds
                }
            }
            let truth = dropAt * period
            let d = try! XCTUnwrap(detectedAt, "no live drop detected at \(bpm) BPM")
            XCTAssertGreaterThanOrEqual(d, truth - 0.02)
            XCTAssertLessThan(d - truth, 0.25, "drop detected \(Int((d - truth) * 1000)) ms late")
            XCTAssertEqual(dropTime!, truth, accuracy: period * 0.15, "drop placed \(Int((dropTime! - truth) * 1000)) ms off the beat")
        }
    }

    func testEngineFiresLiveDropImmediately() {
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 3)
        e.mode = .audio
        e.settings.styleOverride = .edm
        var m = MusicState()
        m.source = .live; m.isSilent = false; m.bpm = 128; m.tempoConfidence = 0.9; m.energy = 0.3; m.section = .breakdown
        var t = 0.0
        for _ in 0..<(44 * 12) { t += 1.0 / 44; m.timestamp = t; m.beatPosition = t * 128 / 60; _ = e.tick(music: m, now: t, dt: 1.0 / 44) }
        m.dropCount = 1
        m.dropBeat = (t * 128 / 60).rounded(.down)
        t += 1.0 / 44; m.timestamp = t; m.beatPosition = t * 128 / 60
        _ = e.tick(music: m, now: t, dt: 1.0 / 44)
        XCTAssertEqual(e.status.special, "DROP!")
    }
}
