import AVFoundation
import ELCCore
import Foundation

/// Loads the bundled MusiCNN genre/mood model once.
enum GenreModel {
    static let shared: MusiCNN? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("Models")) }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Models"))
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exe.appendingPathComponent("../../../Resources/Models").standardizedFileURL)   // swift run from .build/<cfg>/
        for dir in candidates where fm.fileExists(atPath: dir.appendingPathComponent("musicnn_msd.bin").path) {
            if let m = try? MusiCNN(directory: dir) { return m }
        }
        NSLog("ELC Responsive: MusiCNN model not found, using rule-based vibe detection only")
        return nil
    }()
    static let frontend = MusiCNNFrontend()
    static let lock = NSLock()

    /// Tags for a whole file (decoded to 16 kHz mono).
    static func tags(url: URL) -> [String: Double] {
        guard let model = shared, let samples = try? AudioDecoding.mono16k(url: url) else { return [:] }
        lock.lock(); defer { lock.unlock() }
        guard let probs = model.tag(samples16k: samples, frontend: frontend, maxPatches: 24) else { return [:] }
        return model.named(probs)
    }
}

extension AudioDecoding {
    /// Decodes and resamples a file to 16 kHz mono float with AVAudioConverter (MusiCNN input).
    static func mono16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "ELCResponsive", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot create 16 kHz converter"])
        }
        // Down-mix to mono by mixing all channels instead of dropping some.
        converter.downmix = true
        let chunk: AVAudioFrameCount = 1 << 16
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(chunk) * 16000 / inFormat.sampleRate) + 1024) else {
            throw NSError(domain: "ELCResponsive", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate audio buffer"])
        }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * 16000 / inFormat.sampleRate) + 16)
        var done = false
        while !done {
            var err: NSError?
            outBuf.frameLength = 0
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                do {
                    if file.framePosition >= file.length { outStatus.pointee = .endOfStream; return nil }
                    try file.read(into: inBuf, frameCount: chunk)
                    if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                    outStatus.pointee = .haveData
                    return inBuf
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let err { throw err }
            if outBuf.frameLength > 0, let d = outBuf.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error { done = true }
        }
        return out
    }
}

/// Runs MusiCNN on the live input: keeps the last ~3 s at 16 kHz and tags it every few seconds.
final class LiveGenreTagger {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var ring: [Float] = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "elc.musicnn", qos: .utility)
    private var busy = false
    private var lastRun = 0.0
    private var smoothed: [String: Double] = [:]
    private var runs = 0
    /// Called on a background queue with smoothed tag probabilities.
    var onTags: (([String: Double]) -> Void)?

    func start(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        guard GenreModel.shared != nil,
              let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return }
        inFormat = f
        converter = AVAudioConverter(from: f, to: outFormat)
        ring = []
        smoothed = [:]
        runs = 0
        lastRun = ProcessInfo.processInfo.systemUptime
    }

    func stop() {
        lock.lock(); converter = nil; ring = []; lock.unlock()
    }

    /// Feed mono samples at the input sample rate (audio tap thread).
    func feed(_ samples: [Float]) {
        lock.lock()
        guard let conv = converter, let inF = inFormat,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(samples.count)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * 16000 / inF.sampleRate) + 64)
        else { lock.unlock(); return }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var given = false
        conv.convert(to: outBuf, error: nil) { _, st in
            if given { st.pointee = .noDataNow; return nil }
            given = true
            st.pointee = .haveData
            return inBuf
        }
        if let d = outBuf.floatChannelData, outBuf.frameLength > 0 {
            ring.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(outBuf.frameLength)))
            let keep = 16000 * 3 + 1024
            if ring.count > keep { ring.removeFirst(ring.count - keep) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Tag every 5 s (first result after ~3 s).
        let due = now - lastRun > (runs == 0 ? 3.2 : 5) && ring.count >= 16000 * 3 && !busy
        let window = due ? ring : []
        if due { busy = true; lastRun = now }
        lock.unlock()
        guard due else { return }
        queue.async { [weak self] in self?.run(window) }
    }

    private func run(_ window: [Float]) {
        defer { lock.lock(); busy = false; lock.unlock() }
        guard let model = GenreModel.shared else { return }
        // Skip near-silent windows (between songs) so they don't pull the estimate.
        var energy: Float = 0
        for v in window { energy += v * v }
        guard energy / Float(max(window.count, 1)) > 1e-5 else { return }
        GenreModel.lock.lock()
        let probs = model.tag(samples16k: window, frontend: GenreModel.frontend, maxPatches: 1)
        GenreModel.lock.unlock()
        guard let p = probs else { return }
        let named = model.named(p)
        lock.lock()
        runs += 1
        // ~30 s memory: one genre per song, robust against a single odd window.
        let alpha = runs <= 3 ? 1.0 / Double(runs) : 0.18
        for (k, v) in named { smoothed[k] = (smoothed[k] ?? v) * (1 - alpha) + v * alpha }
        let snapshot = smoothed
        lock.unlock()
        onTags?(snapshot)
    }
}
