import Foundation

public struct TrackSection: Codable, Equatable, Sendable {
    public var startBeat: Int
    public var endBeat: Int          // exclusive
    public var kind: MusicSection
    public var startTime: Double
    public var energy: Double
    /// Snare pattern of this section (16ths) and its clarity.
    public var snarePattern: [Double] = []
    public var snareClarity: Double = 0
}

/// Result of analysing a complete audio file. Cached next to the setlist.
public struct TrackAnalysis: Codable, Equatable, Sendable {
    public static let currentVersion = 6
    public var version: Int = TrackAnalysis.currentVersion
    public var duration: Double
    public var bpm: Double
    public var beatTimes: [Double]
    public var downbeatOffset: Int
    public var beatEnergy: [Double]
    public var beatBass: [Double]
    public var sections: [TrackSection]
    /// Peak amplitude overview (0...1) for drawing a waveform.
    public var overview: [Float]
    /// Whole-track audio descriptors and the resulting style / mood.
    public var vibeFeatures = VibeFeatures()
    public var vibe = Vibe()
    /// Whole-track snare pattern (fallback for sections without a clear one).
    public var snarePattern: [Double] = []
    public var snareClarity: Double = 0

    /// Re-runs the vibe model with instrument / vocal evidence from the sound classifier
    /// and/or MusiCNN genre & mood tags.
    public func withEvidence(_ e: [SoundEvidence: Double], tags: [String: Double] = [:]) -> TrackAnalysis {
        var a = self
        for (k, x) in e { a.vibeFeatures.evidence[k.rawValue] = x }
        if !tags.isEmpty { a.vibeFeatures.tags = tags }
        a.vibe = VibeModel.infer(a.vibeFeatures)
        return a
    }

    public var dropTimes: [Double] { sections.filter { $0.kind == .drop }.map { $0.startTime } }
}

public enum TrackAnalyzer {
    /// Delay between a transient and its onset-envelope peak (calibrated on click tracks).
    public static let onsetDelay = 0.015

    /// Analyses a full mono signal. Runs in roughly 1-3 s for a typical 4 minute track.
    public static func analyze(samples: [Float], sampleRate: Double,
                               progress: ((Double) -> Void)? = nil) -> TrackAnalysis {
        let duration = Double(samples.count) / sampleRate
        let extractor = FeatureExtractor(sampleRate: sampleRate)
        let fps = extractor.framesPerSecond
        let hopOffset = Double(extractor.hop) / 2 / sampleRate
        var frames: [FrameFeatures] = []
        frames.reserveCapacity(Int(duration * fps) + 8)
        let chunk = 65536
        var i = 0
        samples.withUnsafeBufferPointer { buf in
            while i < buf.count {
                let n = min(chunk, buf.count - i)
                let slice = UnsafeBufferPointer(rebasing: buf[i..<(i + n)])
                extractor.process(slice) { frames.append($0) }
                i += n
                progress?(0.7 * Double(i) / Double(buf.count))
            }
        }
        let overview = makeOverview(samples, bins: 800)
        guard frames.count > Int(fps * 6) else {
            return TrackAnalysis(duration: duration, bpm: 120, beatTimes: [], downbeatOffset: 0, beatEnergy: [],
                                 beatBass: [], sections: [TrackSection(startBeat: 0, endBeat: 0, kind: .groove,
                                                                       startTime: 0, energy: 0.5)], overview: overview)
        }
        let onsets = frames.map { $0.onset }

        // Tempo: median of window estimates (robust against intros without drums).
        var estimates: [Double] = []
        let win = Int(fps * 12)
        var w = 0
        while w + win <= onsets.count {
            if let e = TempoEstimator.estimate(onsets: Array(onsets[w..<(w + win)]), fps: fps), e.confidence > 0.1 {
                estimates.append(e.bpm)
            }
            w += win / 2
        }
        var bpm = 120.0
        if !estimates.isEmpty {
            // Fold octave errors towards the most common value.
            let sorted = estimates.sorted()
            let median = sorted[sorted.count / 2]
            let folded = estimates.map { e -> Double in
                var x = e
                while x > median * 1.42 { x /= 2 }
                while x < median * 0.71 { x *= 2 }
                return x
            }.sorted()
            bpm = folded[folded.count / 2]
        } else if let e = TempoEstimator.estimate(onsets: onsets, fps: fps) {
            bpm = e.bpm
        }
        progress?(0.8)

        let beatFrames = TempoEstimator.trackBeats(onsets: onsets, fps: fps, bpm: bpm)
        // Onset-envelope peaks trail the actual transient by the analysis window delay (measured ≈ 15 ms).
        var beatTimes = beatFrames.map { frames[min($0, frames.count - 1)].time - hopOffset - TrackAnalyzer.onsetDelay }
        // Make the grid strictly increasing.
        beatTimes = beatTimes.enumerated().filter { $0.offset == 0 || $0.element > beatTimes[$0.offset - 1] + 0.1 }.map { $0.element }
        if beatTimes.count >= 8 {
            // Refine bpm from the actual grid.
            let span = beatTimes.last! - beatTimes.first!
            bpm = 60 * Double(beatTimes.count - 1) / span
        }
        progress?(0.9)

        // Per-beat features
        let nb = beatTimes.count
        var loud = [Double](repeating: -80, count: nb)
        var bass = [Double](repeating: 0, count: nb)
        var accent = [Double](repeating: 0, count: nb)
        var fi = 0
        for b in 0..<nb {
            let start = beatTimes[b]
            let end = b + 1 < nb ? beatTimes[b + 1] : start + 60 / bpm
            var sumDb = 0.0, sumBass = 0.0, cnt = 0.0, acc = 0.0
            while fi < frames.count && frames[fi].time - hopOffset < start - 0.05 { fi += 1 }
            var j = fi
            while j < frames.count && frames[j].time - hopOffset < end - 0.05 {
                let f = frames[j]
                sumDb += f.rmsDb; sumBass += f.bands[0]; cnt += 1
                if f.time - hopOffset < start + 0.07 { acc = max(acc, f.flux[0] + 0.8 * f.flux[3]) }
                j += 1
            }
            if cnt > 0 { loud[b] = sumDb / cnt; bass[b] = sumBass / cnt }
            accent[b] = acc
        }
        let loudN = percentileNormalize(loud, lo: 0.08, hi: 0.95)
        let bassN = percentileNormalize(bass, lo: 0.08, hi: 0.95)
        var energy = zip(loudN, bassN).map { 0.6 * $0 + 0.4 * $1 }
        energy = movingAverage(energy, radius: 2)

        // Downbeat ("the 1"): drum accents alone are ambiguous in four-on-the-floor music, so also use
        // where the song's structure changes (energy / bass jumps) — those almost always land on a 1.
        let raw = zip(loudN, bassN).map { 0.6 * $0 + 0.4 * $1 }
        var accSum = [Double](repeating: 0, count: 4)
        var novSum = [Double](repeating: 0, count: 4)
        let jumps = (0..<nb).map { abs(beatJump(raw, at: $0, span: 4)) }
        for b in 0..<nb {
            accSum[b % 4] += accent[b]
            // only the exact beat where a change peaks counts (neighbours would smear it over all 4 positions)
            let isPeak = (b == 0 || jumps[b] >= jumps[b - 1]) && (b == nb - 1 || jumps[b] > jumps[b + 1])
            if isPeak { novSum[b % 4] += max(0, jumps[b] - 0.08) }
        }
        let accTotal = max(accSum.reduce(0, +), 1e-9), novTotal = max(novSum.reduce(0, +), 1e-9)
        let combined = (0..<4).map { accSum[$0] / accTotal + 1.5 * novSum[$0] / novTotal }
        var downbeat = combined.indices.max(by: { combined[$0] < combined[$1] }) ?? 0

        var sections = detectSections(beatTimes: beatTimes, energy: energy, bass: bassN, downbeat: &downbeat)
        refineBoundaries(&sections, beatTimes: beatTimes, raw: raw, bass: bassN, downbeat: downbeat)

        // Vibe over the whole track, using the beat grid for rhythm descriptors.
        var acc = VibeAccumulator(timeConstant: nil)
        var trackGroove = GrooveTracker(decayPerBar: nil)
        var sectionGrooves = sections.map { _ in GrooveTracker(decayPerBar: nil) }
        var si = 0
        var bi = 0
        let dtFrame = 1 / fps
        for f in frames {
            let t = f.time - hopOffset
            while bi + 1 < nb && beatTimes[bi + 1] <= t { bi += 1 }
            var pos: Double? = nil
            if nb >= 2 && t >= beatTimes[0] && bi + 1 < nb {
                pos = Double(bi) + (t - beatTimes[bi]) / (beatTimes[bi + 1] - beatTimes[bi])
            }
            acc.add(f, dt: dtFrame, beatPosition: pos, downbeatOffset: downbeat)
            if let p = pos {
                trackGroove.add(f, beatPosition: p, downbeatOffset: downbeat)
                while si + 1 < sections.count && sections[si + 1].startBeat <= bi { si += 1 }
                if si < sectionGrooves.count { sectionGrooves[si].add(f, beatPosition: p, downbeatOffset: downbeat) }
            }
        }
        var sectionsWithGroove = sections
        for i in sectionsWithGroove.indices {
            let g = sectionGrooves[i].pattern
            sectionsWithGroove[i].snarePattern = g.slots
            sectionsWithGroove[i].snareClarity = g.clarity
        }
        let clarity = TempoEstimator.estimate(onsets: Array(onsets.prefix(Int(fps * 60))), fps: fps)?.confidence ?? 0.5
        let vf = acc.features(bpm: bpm, pulseClarity: clarity, evidence: [:])
        progress?(1)
        var result = TrackAnalysis(duration: duration, bpm: bpm, beatTimes: beatTimes, downbeatOffset: downbeat,
                                   beatEnergy: energy, beatBass: bassN, sections: sectionsWithGroove, overview: overview)
        let tg = trackGroove.pattern
        result.snarePattern = tg.slots
        result.snareClarity = tg.clarity
        result.vibeFeatures = vf
        result.vibe = VibeModel.infer(vf)
        return result
    }

    static func detectSections(beatTimes: [Double], energy: [Double], bass: [Double], downbeat: inout Int) -> [TrackSection] {
        let nb = beatTimes.count
        guard nb >= 16 else {
            return [TrackSection(startBeat: 0, endBeat: nb, kind: .groove, startTime: beatTimes.first ?? 0, energy: 0.5)]
        }
        // Bars starting at the downbeat.
        var barStarts: [Int] = []
        var b = downbeat
        while b < nb { barStarts.append(b); b += 4 }
        let nBars = barStarts.count
        func barMean(_ arr: [Double], _ bar: Int) -> Double {
            let s = barStarts[bar], e = min(nb, s + 4)
            guard e > s else { return 0 }
            return arr[s..<e].reduce(0, +) / Double(e - s)
        }
        let barE = (0..<nBars).map { barMean(energy, $0) }
        let barB = (0..<nBars).map { barMean(bass, $0) }
        // Novelty between the 4 bars before and after each bar line.
        var novelty = [Double](repeating: 0, count: nBars)
        for i in 2..<max(2, nBars - 1) {
            let a = max(0, i - 4), c = min(nBars, i + 4)
            let preE = barE[a..<i].reduce(0, +) / Double(i - a)
            let postE = barE[i..<c].reduce(0, +) / Double(c - i)
            let preB = barB[a..<i].reduce(0, +) / Double(i - a)
            let postB = barB[i..<c].reduce(0, +) / Double(c - i)
            // Weight the bar right after the line more: drops are instantaneous.
            let instant = abs(barB[i] - barB[i - 1]) * 0.5 + abs(barE[i] - barE[i - 1]) * 0.5
            novelty[i] = abs(postE - preE) + 0.8 * abs(postB - preB) + instant
        }
        var boundaries = [0]
        let minLen = 4
        for i in 1..<nBars where i - boundaries.last! >= minLen {
            let isPeak = novelty[i] >= novelty[max(0, i - 1)] && novelty[i] >= novelty[min(nBars - 1, i + 1)]
            // Prefer phrase-aligned boundaries (multiples of 4 bars) with a lower threshold.
            let thr = (i - boundaries.last!) % 4 == 0 ? 0.18 : 0.3
            if isPeak && novelty[i] > thr { boundaries.append(i) }
        }
        boundaries.append(nBars)

        struct Seg { var startBar: Int; var endBar: Int; var e: Double; var b: Double; var slope: Double }
        var segs: [Seg] = []
        for k in 0..<(boundaries.count - 1) {
            let s = boundaries[k], e = boundaries[k + 1]
            guard e > s else { continue }
            let me = barE[s..<e].reduce(0, +) / Double(e - s)
            let mb = barB[s..<e].reduce(0, +) / Double(e - s)
            let slope = e - s >= 2 ? (barE[e - 1] - barE[s]) : 0
            segs.append(Seg(startBar: s, endBar: e, e: me, b: mb, slope: slope))
        }
        var out: [TrackSection] = []
        for (k, sg) in segs.enumerated() {
            let prev = k > 0 ? segs[k - 1] : nil
            let next = k + 1 < segs.count ? segs[k + 1] : nil
            var kind: MusicSection
            if sg.e < 0.22 {
                kind = .ambient
            } else if let p = prev, sg.e > 0.6, sg.b > 0.5, sg.e - p.e > 0.18 || (p.b < 0.35 && sg.b > 0.6) {
                kind = .drop
            } else if sg.b < 0.35 && sg.e < 0.65 {
                kind = .breakdown
            } else if sg.e > 0.75 {
                kind = .peak
            } else {
                kind = .groove
            }
            // A segment just before a drop with rising energy is a build-up; split long ones.
            if let n = next, n.e - sg.e > 0.18, n.b > 0.5, kind != .drop, kind != .peak {
                let len = sg.endBar - sg.startBar
                if len > 8 && sg.slope <= 0.1 {
                    let splitBar = sg.endBar - 4
                    out.append(makeSection(startBar: sg.startBar, endBar: splitBar, kind: kind, e: sg.e))
                    out.append(makeSection(startBar: splitBar, endBar: sg.endBar, kind: .build, e: sg.e))
                    continue
                }
                kind = .build
            }
            out.append(makeSection(startBar: sg.startBar, endBar: sg.endBar, kind: kind, e: sg.e))
        }
        // Merge neighbours of the same kind (except drops, which must keep their start).
        var merged: [TrackSection] = []
        for s in out {
            if var last = merged.last, last.kind == s.kind, s.kind != .drop {
                last.endBeat = s.endBeat
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        // First section starts at beat 0 (include the pickup beats before the first downbeat).
        if !merged.isEmpty { merged[0].startBeat = 0; merged[0].startTime = beatTimes[0] }
        if !merged.isEmpty { merged[merged.count - 1].endBeat = nb }
        return merged

        func makeSection(startBar: Int, endBar: Int, kind: MusicSection, e: Double) -> TrackSection {
            let sb = barStarts[startBar]
            let eb = endBar < nBars ? barStarts[endBar] : nb
            return TrackSection(startBeat: sb, endBeat: eb, kind: kind, startTime: beatTimes[sb], energy: e)
        }
    }

    /// Mean of `v` over the `span` beats from `b` minus the mean over the `span` beats before it.
    static func beatJump(_ v: [Double], at b: Int, span: Int) -> Double {
        guard b - span >= 0, b + span <= v.count else { return 0 }
        var post = 0.0, pre = 0.0
        for i in b..<(b + span) { post += v[i] }
        for i in (b - span)..<b { pre += v[i] }
        return (post - pre) / Double(span)
    }

    /// Moves each clear section boundary to the exact beat where the music changes (drops land on the
    /// beat the bass comes back, not on the bar where a 4-bar average happened to change).
    static func refineBoundaries(_ sections: inout [TrackSection], beatTimes: [Double], raw: [Double], bass: [Double], downbeat: Int) {
        guard sections.count > 1 else { return }
        for i in 1..<sections.count {
            let s = sections[i].startBeat
            let jumpHere = beatJump(raw, at: s, span: 4)
            // Search ±6 beats, staying clear of the neighbouring boundaries.
            let lo = max(sections[i - 1].startBeat + 4, s - 6)
            let hi = min(sections[i].endBeat - 4, s + 6)
            guard hi > lo else { continue }
            var best = s, bestScore = -Double.greatestFiniteMagnitude
            let up = jumpHere >= 0 || sections[i].kind.isHigh
            for b in lo...hi {
                var j = beatJump(raw, at: b, span: 4) + 0.6 * beatJump(bass, at: b, span: 2)
                if !up { j = -j }
                // strongly prefer downbeats, mildly prefer the original position
                let score = j + ((b - downbeat) % 4 == 0 ? 0.12 : 0) - 0.004 * Double(abs(b - s))
                if score > bestScore { bestScore = score; best = b }
            }
            guard best != s, abs(beatJump(raw, at: best, span: 4)) > 0.08 || sections[i].kind == .drop else { continue }
            sections[i].startBeat = best
            sections[i].startTime = beatTimes[best]
            sections[i - 1].endBeat = best
        }
    }

    static func percentileNormalize(_ v: [Double], lo: Double, hi: Double) -> [Double] {
        guard !v.isEmpty else { return v }
        let s = v.sorted()
        let a = s[Int(Double(s.count - 1) * lo)]
        let b = s[Int(Double(s.count - 1) * hi)]
        let range = max(b - a, 1e-9)
        return v.map { clamp(($0 - a) / range, 0, 1) }
    }

    static func movingAverage(_ v: [Double], radius: Int) -> [Double] {
        guard v.count > 1, radius > 0 else { return v }
        return v.indices.map { i in
            let a = max(0, i - radius), b = min(v.count - 1, i + radius)
            return v[a...b].reduce(0, +) / Double(b - a + 1)
        }
    }

    static func makeOverview(_ samples: [Float], bins: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let per = max(1, samples.count / bins)
        var out: [Float] = []
        out.reserveCapacity(bins)
        var i = 0
        while i < samples.count {
            let e = min(samples.count, i + per)
            var m: Float = 0
            var j = i
            while j < e { m = max(m, abs(samples[j])); j += 4 }
            out.append(min(1, m))
            i = e
        }
        return out
    }
}

/// Produces `MusicState` from an analysed track and the current playback position.
public struct TrackMusicSource: Sendable {
    public let analysis: TrackAnalysis
    public init(analysis: TrackAnalysis) { self.analysis = analysis }

    public func state(atPlaybackTime t: Double, now: Double, lookahead: Double, isPlaying: Bool) -> MusicState {
        var s = MusicState()
        s.source = .track
        s.timestamp = now
        s.bpm = analysis.bpm
        s.downbeatOffset = analysis.downbeatOffset
        s.isSilent = !isPlaying
        s.vibe = analysis.vibe
        s.trackProgress = analysis.duration > 0 ? t / analysis.duration : 0
        let bt = analysis.beatTimes
        let time = t + lookahead
        guard bt.count >= 2 else {
            s.beatPosition = time * analysis.bpm / 60
            s.section = isPlaying ? .groove : .silence
            s.energy = 0.5
            s.tempoConfidence = 0
            return s
        }
        s.tempoConfidence = 1
        let period = 60 / analysis.bpm
        var pos: Double
        if time < bt[0] {
            pos = (time - bt[0]) / period
        } else if time >= bt[bt.count - 1] {
            pos = Double(bt.count - 1) + (time - bt[bt.count - 1]) / period
        } else {
            var lo = 0, hi = bt.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if bt[mid] <= time { lo = mid } else { hi = mid }
            }
            pos = Double(lo) + (time - bt[lo]) / (bt[lo + 1] - bt[lo])
        }
        s.beatPosition = pos
        let bi = clamp(Int(pos.rounded(.down)), 0, bt.count - 1)
        if !analysis.beatEnergy.isEmpty {
            let i0 = min(bi, analysis.beatEnergy.count - 1)
            let i1 = min(i0 + 1, analysis.beatEnergy.count - 1)
            let f = clamp(pos - Double(bi), 0, 1)
            s.energy = lerp(analysis.beatEnergy[i0], analysis.beatEnergy[i1], f)
        }
        if let idx = analysis.sections.lastIndex(where: { $0.startBeat <= bi }) {
            let sec = analysis.sections[idx]
            s.section = isPlaying ? sec.kind : .silence
            s.sectionEnergy = sec.energy
            s.isFinalPeak = sec.kind.isHigh && !analysis.sections[(idx + 1)...].contains { $0.kind.isHigh }
            if sec.snareClarity > 0.35 && sec.snarePattern.count == GrooveTracker.slots {
                s.snarePattern = sec.snarePattern; s.snareClarity = sec.snareClarity
            } else {
                s.snarePattern = analysis.snarePattern; s.snareClarity = analysis.snareClarity
            }
            s.sectionStartBeat = Double(sec.startBeat)
            if idx + 1 < analysis.sections.count {
                let nx = analysis.sections[idx + 1]
                s.nextSection = nx.kind
                s.beatsToNextSection = Double(nx.startBeat) - pos
            }
        } else if let first = analysis.sections.first {
            s.section = isPlaying ? first.kind : .silence
            s.nextSection = analysis.sections.count > 1 ? analysis.sections[1].kind : nil
            s.beatsToNextSection = analysis.sections.count > 1 ? Double(analysis.sections[1].startBeat) - pos : nil
        }
        if time > analysis.duration - 0.5 { s.isSilent = true; s.section = .silence }
        return s
    }
}
