import AVFoundation
import ELCCore
import Foundation
import SoundAnalysis

/// Runs Apple's built-in on-device neural sound classifier (SoundAnalysis, ~300 classes) on the live
/// audio and turns instrument / vocal recognitions into `SoundEvidence` for the vibe model.
final class LiveSoundClassifier: NSObject, SNResultsObserving {
    private var analyzer: SNAudioStreamAnalyzer?
    private let queue = DispatchQueue(label: "elc.soundanalysis", qos: .utility)
    private var format: AVAudioFormat?
    private var framePosition: AVAudioFramePosition = 0
    private var smoothed: [String: Double] = [:]
    private let lock = NSLock()
    private var pendingFrames = 0
    /// Called (on a background queue) with updated evidence.
    var onEvidence: (([SoundEvidence: Double]) -> Void)?

    func start(sampleRate: Double) {
        stop()
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return }
        let a = SNAudioStreamAnalyzer(format: fmt)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try a.add(request, withObserver: self)
        } catch {
            NSLog("ELC Responsive: sound classifier unavailable: \(error)")
            return
        }
        lock.lock()
        analyzer = a
        format = fmt
        framePosition = 0
        smoothed = [:]
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let a = analyzer
        analyzer = nil
        lock.unlock()
        if let a { queue.async { a.completeAnalysis() } }
    }

    /// Feed mono samples (copied, safe to call from the audio thread).
    func feed(_ samples: [Float]) {
        lock.lock()
        guard let a = analyzer, let fmt = format else { lock.unlock(); return }
        // Limit backlog if the classifier can't keep up.
        if pendingFrames > Int(fmt.sampleRate * 2) { lock.unlock(); return }
        pendingFrames += samples.count
        let pos = framePosition
        framePosition += AVAudioFramePosition(samples.count)
        lock.unlock()
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        queue.async { [weak self] in
            a.analyze(buf, atAudioFramePosition: pos)
            guard let self else { return }
            self.lock.lock(); self.pendingFrames -= samples.count; self.lock.unlock()
        }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        var current: [String: Double] = [:]
        for c in r.classifications where SoundEvidence.allLabels.contains(c.identifier) {
            current[c.identifier] = c.confidence
        }
        lock.lock()
        // ~10 s memory (results arrive roughly every 0.5-1 s)
        for label in SoundEvidence.allLabels {
            let old = smoothed[label] ?? 0
            smoothed[label] = old * 0.92 + (current[label] ?? 0) * 0.08
        }
        let snapshot = smoothed
        lock.unlock()
        onEvidence?(SoundEvidence.evidence(from: snapshot))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        NSLog("ELC Responsive: sound classification failed: \(error)")
    }
}

/// Classifies a whole audio file (setlist track) and returns instrument / vocal evidence.
enum FileSoundClassifier {
    private final class Collector: NSObject, SNResultsObserving {
        var values: [String: [Double]] = [:]
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            for c in r.classifications where SoundEvidence.allLabels.contains(c.identifier) {
                values[c.identifier, default: []].append(c.confidence)
            }
        }
    }

    /// Uses the 75th percentile per label over the track, so elements present in part of the song
    /// (e.g. vocals in verses and choruses) still count.
    static func evidence(url: URL) -> [SoundEvidence: Double] {
        guard let analyzer = try? SNAudioFileAnalyzer(url: url),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [:] }
        let collector = Collector()
        do { try analyzer.add(request, withObserver: collector) } catch { return [:] }
        analyzer.analyze()
        var labels: [String: Double] = [:]
        for (label, vals) in collector.values where !vals.isEmpty {
            let sorted = vals.sorted()
            labels[label] = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.75))]
        }
        return SoundEvidence.evidence(from: labels)
    }
}
