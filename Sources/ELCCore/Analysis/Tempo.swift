import Foundation

public enum TempoEstimator {
    /// Estimates tempo from an onset-strength envelope using a weighted autocorrelation.
    /// Returns the BPM and a 0...1 confidence.
    public static func estimate(onsets: [Double], fps: Double, minBPM: Double = 75, maxBPM: Double = 180,
                                preferredBPM: Double = 122) -> (bpm: Double, confidence: Double)? {
        let n = onsets.count
        let minLag = max(2, Int((60 * fps / maxBPM).rounded(.down)))
        let maxLag = Int((60 * fps / minBPM).rounded(.up))
        guard n > maxLag * 2 + 4 else { return nil }
        // Remove local mean and half-wave rectify to emphasise onsets.
        let mean = onsets.reduce(0, +) / Double(n)
        let x = onsets.map { max(0, $0 - mean) }
        func ac(_ lag: Int) -> Double {
            guard lag > 0, lag < n else { return 0 }
            var s = 0.0
            for i in lag..<n { s += x[i] * x[i - lag] }
            return s / Double(n - lag)
        }
        let ac0 = ac0Value(x)
        guard ac0 > 1e-12 else { return nil }
        var acCache = [Double](repeating: 0, count: maxLag * 2 + 2)
        for l in minLag / 2...min(maxLag * 2 + 1, n - 1) { acCache[l] = ac(l) }
        func acc(_ l: Int) -> Double { l < acCache.count ? acCache[l] : 0 }

        var bestLag = minLag
        var bestScore = -Double.greatestFiniteMagnitude
        var scores = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            let bpm = 60 * fps / Double(lag)
            let w = exp(-0.5 * pow(log2(bpm / preferredBPM) / 0.9, 2))
            // Reward lags whose multiples also correlate (metrical structure).
            let s = (acc(lag) + 0.5 * acc(lag * 2) + 0.25 * acc(lag / 2 > 0 ? lag / 2 : lag)) * (0.4 + 0.6 * w)
            scores[lag] = s
            if s > bestScore { bestScore = s; bestLag = lag }
        }
        // Parabolic interpolation for sub-frame precision.
        var lagF = Double(bestLag)
        if bestLag > minLag && bestLag < maxLag {
            let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
            let d = a - 2 * b + c
            if abs(d) > 1e-12 { lagF += clamp(0.5 * (a - c) / d, -0.5, 0.5) }
        }
        let bpm = 60 * fps / lagF
        let conf = clamp(acc(bestLag) / ac0, 0, 1)
        return (bpm, conf)
    }

    private static func ac0Value(_ x: [Double]) -> Double {
        var s = 0.0
        for v in x { s += v * v }
        return s / Double(max(1, x.count))
    }

    /// Ellis (2007) dynamic programming beat tracker. Returns beat frame indices.
    public static func trackBeats(onsets: [Double], fps: Double, bpm: Double, tightness: Double = 100) -> [Int] {
        let n = onsets.count
        guard n > 0 else { return [] }
        let period = 60 * fps / bpm
        // Normalise onset envelope.
        let mean = onsets.reduce(0, +) / Double(n)
        var variance = 0.0
        for v in onsets { variance += (v - mean) * (v - mean) }
        let std = max(1e-9, (variance / Double(n)).squareRoot())
        let o = onsets.map { ($0 - mean) / std }

        var score = [Double](repeating: 0, count: n)
        var backlink = [Int](repeating: -1, count: n)
        let lo = Int((period * 0.5).rounded())
        let hi = Int((period * 2).rounded())
        for t in 0..<n {
            var best = -Double.greatestFiniteMagnitude
            var bestPrev = -1
            if t - lo >= 0 {
                let start = max(0, t - hi)
                for p in start...(t - lo) {
                    let r = log(Double(t - p) / period)
                    let s = score[p] - tightness * r * r
                    if s > best { best = s; bestPrev = p }
                }
            }
            if bestPrev >= 0 && best > 0 {
                score[t] = o[t] + best
                backlink[t] = bestPrev
            } else {
                score[t] = o[t]
            }
        }
        // Pick the best end point in the last period.
        let tailStart = max(0, n - Int(period.rounded()) - 1)
        var end = n - 1
        var endScore = -Double.greatestFiniteMagnitude
        for t in tailStart..<n where score[t] > endScore { endScore = score[t]; end = t }
        var beats: [Int] = []
        var t = end
        while t >= 0 {
            beats.append(t)
            t = backlink[t]
        }
        beats.reverse()
        // Extend the grid to the start of the track if the DP chain stopped early.
        if let first = beats.first {
            var f = Double(first) - period
            var prefix: [Int] = []
            while f >= 0 { prefix.append(Int(f.rounded())); f -= period }
            beats = prefix.reversed() + beats
        }
        return beats
    }
}
