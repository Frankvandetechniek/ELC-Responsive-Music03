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
