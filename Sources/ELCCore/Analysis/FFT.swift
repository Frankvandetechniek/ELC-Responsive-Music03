import Foundation

/// Small radix-2 real FFT magnitude helper (pure Swift, no Accelerate dependency).
/// 2048 points at ~90 frames per second is far below 1% CPU on any Mac.
public final class FFTMagnitude {
    public let size: Int
    private let log2n: Int
    private var re: [Double]
    private var im: [Double]
    private let window: [Double]
    private let cosTable: [Double]
    private let sinTable: [Double]
    private let bitReverse: [Int]

    public init(size: Int) {
        precondition(size > 1 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        self.size = size
        var l = 0; while (1 << l) < size { l += 1 }
        log2n = l
        re = [Double](repeating: 0, count: size)
        im = [Double](repeating: 0, count: size)
        window = (0..<size).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(size)) }
        cosTable = (0..<size / 2).map { cos(-2 * .pi * Double($0) / Double(size)) }
        sinTable = (0..<size / 2).map { sin(-2 * .pi * Double($0) / Double(size)) }
        var br = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var x = i, r = 0
            for _ in 0..<l { r = (r << 1) | (x & 1); x >>= 1 }
            br[i] = r
        }
        bitReverse = br
    }

    /// Returns `size/2` magnitudes for a frame of `size` samples (Hann windowed).
    public func magnitudes(_ frame: [Float]) -> [Double] {
        let n = size
        for i in 0..<n {
            let v = i < frame.count ? Double(frame[i]) : 0
            re[bitReverse[i]] = v * window[i]
            im[bitReverse[i]] = 0
        }
        var len = 2
        while len <= n {
            let half = len / 2
            let step = n / len
            var start = 0
            while start < n {
                var k = 0
                for j in 0..<half {
                    let wr = cosTable[k], wi = sinTable[k]
                    let a = start + j, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    k += step
                }
                start += len
            }
            len <<= 1
        }
        var mags = [Double](repeating: 0, count: n / 2)
        let norm = 2.0 / Double(n)
        for i in 0..<n / 2 { mags[i] = (re[i] * re[i] + im[i] * im[i]).squareRoot() * norm }
        return mags
    }
}
