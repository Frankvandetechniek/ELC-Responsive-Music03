import XCTest
@testable import ELCCore
/// Developer tool: prints the analysis and the simulated look changes for a real song.
/// Decode a song to raw mono float32 (22.05 kHz, and 16 kHz for the genre model), then run e.g.
///   BENTE=song_22050.f32 BENTE16=song_16k.f32 swift test -c release --filter SongProbe
/// Does nothing during normal test runs.
final class SongProbe: XCTestCase {
    func testProbe() throws {
        guard let path = ProcessInfo.processInfo.environment["BENTE"] else { return }
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        let samples: [Float] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var a = TrackAnalyzer.analyze(samples: samples, sampleRate: 22050)
        if let p16 = ProcessInfo.processInfo.environment["BENTE16"] {
            let d16 = try Data(contentsOf: URL(fileURLWithPath: p16))
            let s16: [Float] = d16.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let model = try MusiCNN(directory: MusiCNNTests.repoRoot.appendingPathComponent("Resources/Models"))
            let tags = model.named(model.tag(samples16k: s16, frontend: MusiCNNFrontend(), maxPatches: 24)!)
            print("PROBE tags", tags.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) \(Int($0.value * 100))" })
            a = a.withEvidence([:], tags: tags)
            print("PROBE vibe with tags: \(a.vibe.style.rawValue) conf \(Int(a.vibe.styleConfidence * 100))% arousal \(String(format: "%.2f", a.vibe.arousal)) valence \(String(format: "%.2f", a.vibe.valence)) scores \(a.vibe.scores.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \(Int($0.value * 100))" })")
        }
        print("PROBE bpm \(String(format: "%.2f", a.bpm)) downbeat \(a.downbeatOffset) beats \(a.beatTimes.count)")
        print("PROBE vibe \(a.vibe.style.rawValue) arousal \(String(format: "%.2f", a.vibe.arousal)) feats 4otf \(String(format: "%.2f", a.vibeFeatures.fourOnFloor)) backbeat \(String(format: "%.2f", a.vibeFeatures.backbeat))")
        for s in a.sections {
            let end = s.endBeat < a.beatTimes.count ? a.beatTimes[s.endBeat] : a.duration
            print("PROBE section \(s.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(format: "%6.1f", s.startTime))s - \(String(format: "%6.1f", end))s  bars \((s.endBeat - s.startBeat) / 4)  e=\(String(format: "%.2f", s.energy))")
        }
        // per-4-bar energy / bass / activity view
        var line = ""
        var b = a.downbeatOffset
        while b + 16 <= a.beatEnergy.count {
            let e = a.beatEnergy[b..<(b + 16)].reduce(0, +) / 16
            let bs = a.beatBass[b..<(b + 16)].reduce(0, +) / 16
            line += String(format: "%5.0fs e%.2f b%.2f\n", a.beatTimes[b], e, bs)
            b += 16
        }
        print("PROBE 4-bar\n" + line)
        for bi in 0..<a.beatTimes.count where a.beatTimes[bi] > 19 && a.beatTimes[bi] < 28 {
            print("PROBE beat \(bi) t=\(String(format: "%.2f", a.beatTimes[bi])) inBar \((bi - a.downbeatOffset) % 4) e=\(String(format: "%.2f", a.beatEnergy[bi])) bass=\(String(format: "%.2f", a.beatBass[bi]))")
        }
        // simulate the engine with pop style
        let src = TrackMusicSource(analysis: a)
        let e = ShowEngine(rig: Rig.elcDefault(), seed: 3)
        e.mode = .audio
        var t = 0.0, last = e.cueChanges
        let dt = 1.0 / 44
        var lastSpecial = ""
        while t < a.duration - 1 {
            t += dt
            _ = e.tick(music: src.state(atPlaybackTime: t, now: t, lookahead: 0, isPlaying: true), now: t, dt: dt)
            if e.cueChanges != last { print("PROBE look change at \(String(format: "%.1f", t))s section \(e.status.section.rawValue) level \(e.status.levelName) style \(e.status.styleName)"); last = e.cueChanges }
            let sp = e.status.special.hasPrefix("Build-up") ? "Build-up" : e.status.special
            if sp != lastSpecial { if !sp.isEmpty { print("PROBE   special '\(sp)' at \(String(format: "%.1f", t))s") }; lastSpecial = sp }
        }
    }
}
