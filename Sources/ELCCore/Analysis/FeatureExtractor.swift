import Foundation

/// Per-hop spectral features.
public struct FrameFeatures: Sendable {
    public var time: Double
    public var rmsDb: Double
    /// Band energies (linear magnitude averages): sub (30-150 Hz), low-mid (150-500), mid (500-4k), high (4k-14k)
    public var bands: [Double]
    /// Positive spectral flux per band (onset strength).
    public var flux: [Double]
    /// Combined onset strength used for tempo/beat tracking.
    public var onset: Double
}

/// Converts a stream of mono samples into `FrameFeatures` every `hop` samples.
public final class FeatureExtractor {
    public let sampleRate: Double
    public let fftSize: Int
    public let hop: Int
    public var framesPerSecond: Double { sampleRate / Double(hop) }

    private let fft: FFTMagnitude
    private var buffer: [Float]
    private var filled = 0
    private var pendingSinceHop = 0
    private var prevLog: [Double]
    private var bandBins: [Range<Int>] = []
    private var samplesProcessed: Int = 0

    public static let bandEdges: [(Double, Double)] = [(30, 150), (150, 500), (500, 4000), (4000, 14000)]

    public init(sampleRate: Double, fftSize: Int = 2048, hop: Int? = nil) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        // ~10.7 ms hop at 48 kHz, ~11.6 ms at 44.1 kHz
        self.hop = hop ?? (sampleRate > 60000 ? 1024 : 512)
        fft = FFTMagnitude(size: fftSize)
        buffer = [Float](repeating: 0, count: fftSize)
        prevLog = [Double](repeating: 0, count: fftSize / 2)
        let binHz = sampleRate / Double(fftSize)
        bandBins = Self.bandEdges.map { lo, hi in
            let a = max(1, Int(lo / binHz))
            let b = min(fftSize / 2, max(a + 1, Int(hi / binHz)))
            return a..<b
        }
    }

    /// Feeds samples; calls `handler` for every completed hop.
    public func process(_ samples: UnsafeBufferPointer<Float>, handler: (FrameFeatures) -> Void) {
        var idx = 0
        let n = samples.count
        while idx < n {
            let take = min(hop - pendingSinceHop, n - idx)
            // shift into the analysis window
            if take >= fftSize {
                for i in 0..<fftSize { buffer[i] = samples[idx + take - fftSize + i] }
            } else {
                buffer.removeFirst(take)
                for i in 0..<take { buffer.append(samples[idx + i]) }
            }
            idx += take
            pendingSinceHop += take
            samplesProcessed += take
            filled = min(fftSize, filled + take)
            if pendingSinceHop >= hop {
                pendingSinceHop = 0
                handler(analyzeWindow())
            }
        }
    }

    public func process(_ samples: [Float], handler: (FrameFeatures) -> Void) {
        samples.withUnsafeBufferPointer { process($0, handler: handler) }
    }

    private func analyzeWindow() -> FrameFeatures {
        var sumSq = 0.0
        let start = fftSize - hop
        for i in start..<fftSize { let v = Double(buffer[i]); sumSq += v * v }
        let rms = (sumSq / Double(hop)).squareRoot()
        let rmsDb = 20 * log10(max(rms, 1e-7))
        let mags = fft.magnitudes(buffer)
        var bands = [Double](repeating: 0, count: 4)
        var flux = [Double](repeating: 0, count: 4)
        for (bi, r) in bandBins.enumerated() {
            var e = 0.0, f = 0.0
            for k in r {
                let m = mags[k]
                e += m
                let l = log(1 + 1000 * m)
                let d = l - prevLog[k]
                if d > 0 { f += d }
            }
            bands[bi] = e / Double(r.count)
            flux[bi] = f / Double(r.count)
        }
        for k in 0..<mags.count { prevLog[k] = log(1 + 1000 * mags[k]) }
        let onset = 1.6 * flux[0] + 0.8 * flux[1] + 1.0 * flux[2] + 0.6 * flux[3]
        let time = Double(samplesProcessed) / sampleRate
        return FrameFeatures(time: time, rmsDb: rmsDb, bands: bands, flux: flux, onset: onset)
    }
}
