import XCTest
@testable import ELCCore

/// End-to-end: a slow but energetic pop song → analysis → playback source → show engine.
/// Looks may only change where the song actually changes (intro / verse / chorus / outro).
final class SongStructureTests: XCTestCase {
    func testSlowPopSongSectionsMatchTheSong() {
        for bpm in [78.0, 86.0] {
            let song = SyntheticPopSong(bpm: bpm, sr: 22050)
            let a = TrackAnalyzer.analyze(samples: song.render(), sampleRate: 22050)
            XCTAssertEqual(a.bpm, bpm, accuracy: 1.5, "tempo read wrong")
            let beat = 60 / bpm
            let truth = song.boundaryBars.map { Double($0 * 4) * beat }
            // every detected boundary is a real one (±1 beat), and every real one is found
            for s in a.sections {
                XCTAssertTrue(truth.contains { abs($0 - s.startTime) < beat * 1.01 },
                              "invented boundary at \(s.startTime)s (\(s.kind.rawValue)) — \(a.sections.map { "\($0.kind.rawValue)@\(Int($0.startTime))" })")
            }
            for t in truth {
                XCTAssertTrue(a.sections.contains { abs($0.startTime - t) < beat * 1.01 }, "missed boundary at \(t)s")
            }
            // both verses get the same label (so they get the same look); no build-ups invented
            let kinds = a.sections.map { $0.kind }
            XCTAssertFalse(kinds.contains(.build), "\(kinds)")
            let verses = a.sections.filter { abs($0.startTime - truth[1]) < beat || abs($0.startTime - truth[3]) < beat }
            XCTAssertEqual(verses.count, 2)
            XCTAssertEqual(verses[0].kind, verses[1].kind)
        }
    }

    func testLookChangesOnlyWhereThePopSongChanges() {
        let bpm = 82.0
        let song = SyntheticPopSong(bpm: bpm, sr: 22050)
        var analysis = TrackAnalyzer.analyze(samples: song.render(), sampleRate: 22050)
        var v = analysis.vibe; v.style = .pop; v.isReady = true; analysis.vibe = v
        let src = TrackMusicSource(analysis: analysis)
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 8)
        e.mode = .audio
        e.settings.styleOverride = .pop
        let dt = 1.0 / 44
        var t = 0.0, last = e.cueChanges
        var changes: [Double] = []
        while t < analysis.duration - 1 {
            t += dt
            _ = e.tick(music: src.state(atPlaybackTime: t, now: t, lookahead: 0, isPlaying: true), now: t, dt: dt)
            if e.cueChanges != last { changes.append(t); last = e.cueChanges }
        }
        let beat = 60 / bpm
        let truth = song.boundaryBars.map { Double($0 * 4) * beat }
        XCTAssertGreaterThanOrEqual(changes.count, 4)
        for c in changes {
            XCTAssertTrue(truth.contains { c >= $0 - 0.05 && c < $0 + beat * 1.05 },
                          "look changed at \(String(format: "%.1f", c))s, not at a song boundary \(truth.map { Int($0) })")
        }
    }
}

final class TempoOctaveTests: XCTestCase {
    func testDoubledTempoOnASlowPopSongIsHalved() {
        let sr = 22050.0
        let song = SyntheticPopSong(bpm: 80, sr: sr)
        let ex = FeatureExtractor(sampleRate: sr)
        var frames: [FrameFeatures] = []
        ex.process(song.render()) { frames.append($0) }
        // As if the tempo estimator had read the busy hi-hats as 160 BPM:
        XCTAssertEqual(TrackAnalyzer.backbeatOctaveCheck(bpm: 160, frames: frames, fps: ex.framesPerSecond), 80, accuracy: 0.01)
        // A correct reading is left alone.
        XCTAssertEqual(TrackAnalyzer.backbeatOctaveCheck(bpm: 80, frames: frames, fps: ex.framesPerSecond), 80, accuracy: 0.01)
    }
}
