import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

// Swift port of MusiCNN (MSD_musicnn) — Pons & Serra, "musicnn: pre-trained convolutional neural
// networks for music audio tagging" (ISMIR 2019 LBD), Music Technology Group, UPF. ISC license.
// Trained on the Million Song Dataset to predict 50 Last.fm tags (genres, moods, instruments, eras).
// Weights: Resources/Models/musicnn_msd.bin (+ .json manifest), exported from the original checkpoint.

/// librosa-compatible log-mel frontend used by MusiCNN:
/// 16 kHz, n_fft 512, hop 256, 96 Slaney mel bands (0–8 kHz), power 2, centre/reflect padding,
/// log10(10000·S + 1).
public final class MusiCNNFrontend {
    public static let sampleRate = 16000.0
    public static let nFFT = 512
    public static let hop = 256
    public static let nMels = 96
    public static let patchFrames = 187   // ≈ 3 s

    private let fft = FFTMagnitude(size: nFFT)
    /// [mel][bin] weights (96 × 257)
    public let filterbank: [[Float]]

    public init() {
        filterbank = Self.slaneyMelFilterbank(sr: Self.sampleRate, nFFT: Self.nFFT, nMels: Self.nMels)
    }

    // librosa.filters.mel(sr, n_fft, n_mels) with htk=False, norm='slaney'
    static func hzToMel(_ f: Double) -> Double {
        let fsp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fsp, logstep = log(6.4) / 27
        return f >= minLogHz ? minLogMel + log(f / minLogHz) / logstep : f / fsp
    }
    static func melToHz(_ m: Double) -> Double {
        let fsp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fsp, logstep = log(6.4) / 27
        return m >= minLogMel ? minLogHz * exp(logstep * (m - minLogMel)) : fsp * m
    }
    static func slaneyMelFilterbank(sr: Double, nFFT: Int, nMels: Int) -> [[Float]] {
        let nBins = nFFT / 2 + 1
        let fftFreqs = (0..<nBins).map { Double($0) * sr / Double(nFFT) }
        let mMin = hzToMel(0), mMax = hzToMel(sr / 2)
        let melF = (0..<(nMels + 2)).map { melToHz(mMin + (mMax - mMin) * Double($0) / Double(nMels + 1)) }
        var w = [[Float]](repeating: [Float](repeating: 0, count: nBins), count: nMels)
        for i in 0..<nMels {
            let fdiffLo = melF[i + 1] - melF[i], fdiffHi = melF[i + 2] - melF[i + 1]
            let enorm = 2 / (melF[i + 2] - melF[i])
            for k in 0..<nBins {
                let lower = (fftFreqs[k] - melF[i]) / fdiffLo
                let upper = (melF[i + 2] - fftFreqs[k]) / fdiffHi
                w[i][k] = Float(max(0, min(lower, upper)) * enorm)
            }
        }
        return w
    }

    /// Log-mel frames (row-major `frames × 96`) for 16 kHz mono audio.
    public func logMel(_ samples: [Float]) -> (data: [Float], frames: Int) {
        let n = Self.nFFT, half = n / 2
        guard samples.count > half + 1 else { return ([], 0) }
        // centre=True: reflect-pad n/2 on both sides
        var padded = [Float](repeating: 0, count: samples.count + n)
        for i in 0..<samples.count { padded[i + half] = samples[i] }
        for i in 0..<half {
            padded[half - 1 - i] = samples[min(i + 1, samples.count - 1)]
            padded[half + samples.count + i] = samples[max(0, samples.count - 2 - i)]
        }
        let frames = 1 + samples.count / Self.hop
        var out = [Float](repeating: 0, count: frames * Self.nMels)
        padded.withUnsafeBufferPointer { buf in
            for f in 0..<frames {
                let start = f * Self.hop
                guard start + n <= buf.count else { break }
                let p = fft.power(UnsafeBufferPointer(rebasing: buf[start..<(start + n)]))
                for m in 0..<Self.nMels {
                    var s: Float = 0
                    let row = filterbank[m]
                    for k in 0..<p.count where row[k] != 0 { s += row[k] * p[k] }
                    out[f * Self.nMels + m] = log10(10000 * s + 1)
                }
            }
        }
        return (out, frames)
    }
}

/// The MusiCNN network (inference only).
public final class MusiCNN: @unchecked Sendable {
    public let labels: [String]
    private var t: [String: [Float]] = [:]
    private var shapes: [String: [Int]] = [:]

    struct Manifest: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let offset: Int; let count: Int }
        let tensors: [Tensor]
        let labels: [String]
    }

    public init(weights: Data, manifest: Data) throws {
        let m = try JSONDecoder().decode(Manifest.self, from: manifest)
        labels = m.labels
        let floats: [Float] = weights.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        for tensor in m.tensors {
            guard tensor.offset + tensor.count <= floats.count else {
                throw NSError(domain: "MusiCNN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Weights file too small"])
            }
            t[tensor.name] = Array(floats[tensor.offset..<(tensor.offset + tensor.count)])
            shapes[tensor.name] = tensor.shape
        }
        guard t["dense_1/kernel"]?.count == 200 * 50 else {
            throw NSError(domain: "MusiCNN", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected MusiCNN weights"])
        }
    }

    /// Loads the model from a directory containing musicnn_msd.bin / musicnn_msd.json.
    public convenience init(directory: URL) throws {
        try self.init(weights: try Data(contentsOf: directory.appendingPathComponent("musicnn_msd.bin")),
                      manifest: try Data(contentsOf: directory.appendingPathComponent("musicnn_msd.json")))
    }

    // MARK: Layers

    /// Batch norm (inference) over the last axis (`channels`), in place.
    private func bn(_ x: inout [Float], _ name: String, channels: Int) {
        let mean = t[name + "/moving_mean"]!, varr = t[name + "/moving_variance"]!
        let gamma = t[name + "/gamma"]!, beta = t[name + "/beta"]!
        var scale = [Float](repeating: 0, count: channels), shift = [Float](repeating: 0, count: channels)
        for c in 0..<channels {
            scale[c] = gamma[c] / (varr[c] + 1e-3).squareRoot()
            shift[c] = beta[c] - mean[c] * scale[c]
        }
        let n = x.count / channels
        x.withUnsafeMutableBufferPointer { p in
            for i in 0..<n {
                let base = i * channels
                for c in 0..<channels { p[base + c] = p[base + c] * scale[c] + shift[c] }
            }
        }
    }

    /// C[M×N] = A[M×K] · B[K×N] (row-major)
    static func gemm(_ a: [Float], _ b: [Float], m: Int, k: Int, n: Int) -> [Float] {
        var c = [Float](repeating: 0, count: m * n)
        #if canImport(Accelerate)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(m), Int32(n), Int32(k),
                    1, a, Int32(k), b, Int32(n), 0, &c, Int32(n))
        #else
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                c.withUnsafeMutableBufferPointer { pc in
                    for i in 0..<m {
                        let crow = i * n
                        for kk in 0..<k {
                            let av = pa[i * k + kk]
                            if av == 0 { continue }
                            let brow = kk * n
                            for j in 0..<n { pc[crow + j] += av * pb[brow + j] }
                        }
                    }
                }
            }
        }
        #endif
        return c
    }

    /// 2-D convolution of a single-channel input `x` (rows × cols) with a TF kernel [kh, kw, 1, out],
    /// with explicit row padding (before/after) and no column padding ("valid" along columns),
    /// followed by bias + ReLU. Returns (outRows × outCols × out).
    private func conv(_ x: [Float], rows: Int, cols: Int, kernel name: String, padTop: Int, padBottom: Int,
                      padLeft: Int = 0, padRight: Int = 0) -> (data: [Float], rows: Int, cols: Int, ch: Int) {
        let shape = shapes[name + "/kernel"]!
        let kh = shape[0], kw = shape[1], outC = shape[3]
        let pr = rows + padTop + padBottom, pc = cols + padLeft + padRight
        let oRows = pr - kh + 1, oCols = pc - kw + 1
        let kSize = kh * kw
        var col = [Float](repeating: 0, count: oRows * oCols * kSize)
        x.withUnsafeBufferPointer { px in
            col.withUnsafeMutableBufferPointer { pcl in
                for r in 0..<oRows {
                    for c in 0..<oCols {
                        let base = (r * oCols + c) * kSize
                        for i in 0..<kh {
                            let srcR = r + i - padTop
                            if srcR < 0 || srcR >= rows { continue }
                            for j in 0..<kw {
                                let srcC = c + j - padLeft
                                if srcC < 0 || srcC >= cols { continue }
                                pcl[base + i * kw + j] = px[srcR * cols + srcC]
                            }
                        }
                    }
                }
            }
        }
        var y = Self.gemm(col, t[name + "/kernel"]!, m: oRows * oCols, k: kSize, n: outC)
        let bias = t[name + "/bias"]!
        y.withUnsafeMutableBufferPointer { p in
            for i in 0..<(oRows * oCols) {
                for o in 0..<outC { p[i * outC + o] = max(0, p[i * outC + o] + bias[o]) }
            }
        }
        return (y, oRows, oCols, outC)
    }

    /// Max over the column (frequency) axis: (rows × cols × ch) → (rows × ch)
    private func maxOverCols(_ x: [Float], rows: Int, cols: Int, ch: Int) -> [Float] {
        var out = [Float](repeating: -.greatestFiniteMagnitude, count: rows * ch)
        for r in 0..<rows {
            for c in 0..<cols {
                let base = (r * cols + c) * ch
                for k in 0..<ch { out[r * ch + k] = max(out[r * ch + k], x[base + k]) }
            }
        }
        return out
    }

    /// Tag probabilities (50, sigmoid) for one log-mel patch (`frames × 96`, row-major).
    public func predict(logMel: [Float], frames: Int) -> [Float] {
        let nMels = MusiCNNFrontend.nMels
        var x = logMel
        bn(&x, "batch_normalization", channels: 1)

        // Front-end: timbral (7×38, 7×67 on time-padded input) and temporal (128/64/32×1, 'same') filters
        var f74 = conv(x, rows: frames, cols: nMels, kernel: "conv2d", padTop: 3, padBottom: 3)
        bn(&f74.data, "batch_normalization_1", channels: f74.ch)
        let p74 = maxOverCols(f74.data, rows: f74.rows, cols: f74.cols, ch: f74.ch)
        var f77 = conv(x, rows: frames, cols: nMels, kernel: "conv2d_1", padTop: 3, padBottom: 3)
        bn(&f77.data, "batch_normalization_2", channels: f77.ch)
        let p77 = maxOverCols(f77.data, rows: f77.rows, cols: f77.cols, ch: f77.ch)
        var temporal: [[Float]] = []
        for (name, bnName, k) in [("conv2d_2", "batch_normalization_3", 128), ("conv2d_3", "batch_normalization_4", 64),
                                  ("conv2d_4", "batch_normalization_5", 32)] {
            // TF 'SAME' padding for even kernels: (k-1)/2 before, the rest after
            var s = conv(x, rows: frames, cols: nMels, kernel: name, padTop: (k - 1) / 2, padBottom: k - 1 - (k - 1) / 2)
            bn(&s.data, bnName, channels: s.ch)
            temporal.append(maxOverCols(s.data, rows: s.rows, cols: s.cols, ch: s.ch))
        }
        let frontParts: [([Float], Int)] = [(p74, 204), (p77, 204), (temporal[0], 51), (temporal[1], 51), (temporal[2], 51)]
        let frontC = frontParts.reduce(0) { $0 + $1.1 }   // 561
        var front = [Float](repeating: 0, count: frames * frontC)
        for r in 0..<frames {
            var off = 0
            for (part, c) in frontParts {
                for k in 0..<c { front[r * frontC + off + k] = part[r * c + k] }
                off += c
            }
        }

        // Mid-end: three 7×C convolutions with residual connections
        var c1 = conv(front, rows: frames, cols: frontC, kernel: "conv2d_5", padTop: 3, padBottom: 3).data
        bn(&c1, "batch_normalization_6", channels: 64)
        var c2 = conv(c1, rows: frames, cols: 64, kernel: "conv2d_6", padTop: 3, padBottom: 3).data
        bn(&c2, "batch_normalization_7", channels: 64)
        for i in 0..<c2.count { c2[i] += c1[i] }
        var c3 = conv(c2, rows: frames, cols: 64, kernel: "conv2d_7", padTop: 3, padBottom: 3).data
        bn(&c3, "batch_normalization_8", channels: 64)
        for i in 0..<c3.count { c3[i] += c2[i] }

        // Back-end: global max + mean pooling over time (interleaved), dense layers
        let midC = frontC + 64 * 3   // 753
        var flat = [Float](repeating: 0, count: midC * 2)
        for ch in 0..<midC {
            var mx = -Float.greatestFiniteMagnitude, sum: Float = 0
            for r in 0..<frames {
                let v: Float
                if ch < frontC { v = front[r * frontC + ch] }
                else if ch < frontC + 64 { v = c1[r * 64 + ch - frontC] }
                else if ch < frontC + 128 { v = c2[r * 64 + ch - frontC - 64] }
                else { v = c3[r * 64 + ch - frontC - 128] }
                mx = max(mx, v); sum += v
            }
            flat[ch * 2] = mx
            flat[ch * 2 + 1] = sum / Float(frames)
        }
        bn(&flat, "batch_normalization_9", channels: midC * 2)
        var h = Self.gemm(flat, t["dense/kernel"]!, m: 1, k: midC * 2, n: 200)
        let db = t["dense/bias"]!
        for i in 0..<200 { h[i] = max(0, h[i] + db[i]) }
        bn(&h, "batch_normalization_10", channels: 200)
        var logits = Self.gemm(h, t["dense_1/kernel"]!, m: 1, k: 200, n: 50)
        let ob = t["dense_1/bias"]!
        for i in 0..<50 { logits[i] = 1 / (1 + exp(-(logits[i] + ob[i]))) }
        return logits
    }

    /// Average tag probabilities over a 16 kHz signal, using up to `maxPatches` evenly spaced 3 s patches
    /// (skipping the first and last 5 % of a track).
    public func tag(samples16k: [Float], frontend: MusiCNNFrontend, maxPatches: Int = 24) -> [Float]? {
        let (mel, frames) = frontend.logMel(samples16k)
        let pf = MusiCNNFrontend.patchFrames
        guard frames >= pf else { return nil }
        let available = frames / pf
        let skip = available > 6 ? max(0, Int(Double(frames) * 0.05)) : 0
        let usable = max(pf, frames - 2 * skip)
        let count = max(1, min(maxPatches, usable / pf))
        let stride = count > 1 ? (usable - pf) / (count - 1) : 0
        var sum = [Float](repeating: 0, count: 50)
        for i in 0..<count {
            let start = skip + i * stride
            let patch = Array(mel[(start * MusiCNNFrontend.nMels)..<((start + pf) * MusiCNNFrontend.nMels)])
            let p = predict(logMel: patch, frames: pf)
            for k in 0..<50 { sum[k] += p[k] }
        }
        return sum.map { $0 / Float(count) }
    }

    /// Named tag probabilities.
    public func named(_ probs: [Float]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (i, l) in labels.enumerated() where i < probs.count { out[l] = Double(probs[i]) }
        return out
    }
}
