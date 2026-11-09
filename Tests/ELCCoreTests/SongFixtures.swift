import Foundation
@testable import ELCCore

/// A synthetic pop song: slow tempo but busy (16th hats), kick on 1 & 3, snare on 2 & 4.
/// Structure in bars: [intro 4] [verse 16] [chorus 16] [verse 16] [chorus 16] [outro 4].
/// Verses contain normal variation (a drum fill every 8th bar, a vocal-like swell) that must NOT
/// be mistaken for a new section.
struct SyntheticPopSong {
    let bpm: Double
    let sr: Double
    let sections: [(name: String, bars: Int)] = [("intro", 4), ("verse", 16), ("chorus", 16), ("verse", 16), ("chorus", 16), ("outro", 4)]

    var boundaryBars: [Int] {
        var b = 0
        var out: [Int] = []
        for s in sections { out.append(b); b += s.bars }
        return out
    }
    var totalBars: Int { sections.reduce(0) { $0 + $1.bars } }

    func render() -> [Float] {
        let beat = 60 / bpm
        let n = Int(Double(totalBars * 4) * beat * sr)
        var out = [Float](repeating: 0, count: n)
        var rng = SeededRandom(seed: 77)
        // which section each bar is in
        var barKind: [String] = []
        for s in sections { barKind += Array(repeating: s.name, count: s.bars) }
        let chord: [[Double]] = [[220, 277.2, 329.6], [196, 246.9, 293.7], [174.6, 220, 261.6], [196, 246.9, 293.7]]
        for i in 0..<n {
            let t = Double(i) / sr
            let beatPos = t / beat
            let bar = min(Int(beatPos / 4), totalBars - 1)
            let inBar = beatPos - Double(bar * 4)
            let bIdx = Int(inBar)
            let ph = (inBar - Double(bIdx)) * beat
            let kind = barKind[bar]
            let barInSection = bar - (boundaryBars.last { $0 <= bar } ?? 0)
            let chorus = kind == "chorus"
            let drums = kind != "intro" && kind != "outro"
            var v = 0.0
            if drums {
                if bIdx == 0 || bIdx == 2 || (chorus && bIdx == 1 && ph > beat * 0.5) {
                    v += (chorus ? 0.85 : 0.7) * exp(-ph * 16) * sin(2 * .pi * (48 + 70 * exp(-ph * 28)) * ph)
                }
                let fill = barInSection % 8 == 7 && bIdx == 3      // tom fill on the last beat of every 8 bars
                if bIdx == 1 || bIdx == 3 || fill {
                    let sp = fill ? fmodPositive(ph, beat / 4) : ph
                    v += (chorus ? 0.5 : 0.4) * exp(-sp * 22) * (rng.unit() * 2 - 1) + 0.25 * exp(-sp * 30) * sin(2 * .pi * 185 * sp)
                }
                let s16 = fmodPositive(t, beat / 4)
                v += (chorus ? 0.08 : 0.06) * exp(-s16 * 120) * (rng.unit() * 2 - 1)
            }
            // harmony + bass; chorus louder, verse swells within 4 bars like a vocal phrase
            let swell = kind == "verse" ? 0.75 + 0.25 * sin(2 * .pi * Double(barInSection) / 4) : 1
            let ch = chord[bar % 4]
            for f in ch { v += (chorus ? 0.07 : 0.05) * swell * sin(2 * .pi * f * t) }
            v += (chorus ? 0.22 : 0.15) * sin(2 * .pi * ch[0] / 4 * t)
            out[i] = Float(v)
        }
        return out
    }
}
