import AVFoundation
import Foundation
import ELCCore

struct SetlistTrack: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var title: String
    var duration: Double = 0
    var analysis: TrackAnalysis? = nil
    /// Operator tempo correction for this track: 0.5 (half), 2 (double) or nil (automatic).
    var tempoScale: Double? = nil

    var url: URL { URL(fileURLWithPath: path) }

    enum CodingKeys: String, CodingKey { case id, path, title, duration, tempoScale }
}

enum AudioDecoding {
    /// Decodes a wav/mp3/aiff/m4a file to mono float samples at roughly 22-24 kHz (enough for analysis).
    static func monoSamples(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let chans = Int(format.channelCount)
        let decimate = sr >= 88000 ? 4 : (sr >= 32000 ? 2 : 1)
        var out: [Float] = []
        out.reserveCapacity(Int(file.length) / decimate + 16)
        let chunk: AVAudioFrameCount = 1 << 18
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw NSError(domain: "ELCResponsive", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate audio buffer"])
        }
        var acc: Float = 0
        var accN = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            let scale = 1 / Float(max(chans, 1))
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<chans { v += data[c][i] }
                acc += v * scale
                accN += 1
                if accN == decimate {
                    out.append(acc / Float(decimate))
                    acc = 0; accN = 0
                }
            }
        }
        return (out, sr / Double(decimate))
    }
}

/// Caches analysis results so a setlist only has to be analysed once.
enum AnalysisCache {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ELC Responsive/Analysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func key(for url: URL, tempoScale: Double? = nil) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 1469598103934665603
        let scale = tempoScale.map { "|x\($0)" } ?? ""
        for b in "\(url.path)|\(size)|\(Int(mtime))\(scale)".utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }

    static func load(for url: URL, tempoScale: Double? = nil) -> TrackAnalysis? {
        let f = directory.appendingPathComponent(key(for: url, tempoScale: tempoScale) + ".json")
        guard let data = try? Data(contentsOf: f),
              let a = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
              a.version == TrackAnalysis.currentVersion else { return nil }
        return a
    }

    static func save(_ a: TrackAnalysis, for url: URL, tempoScale: Double? = nil) {
        let f = directory.appendingPathComponent(key(for: url, tempoScale: tempoScale) + ".json")
        if let data = try? JSONEncoder().encode(a) { try? data.write(to: f) }
    }
}

/// Plays setlist tracks and provides beat-accurate `MusicState` from the pre-analysed beat grid.
final class SetlistPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let tapAnalyzer = Locked<LiveAnalyzer?>(nil)
    private var mono: [Float] = []

    private struct PlayState {
        var file: AVAudioFile?
        var source: TrackMusicSource?
        var segmentStart: Double = 0
        var playing = false
        var pausedAt: Double = 0
        var generation = 0
    }
    private let state = Locked(PlayState())
    let level = Locked<Float>(0)

    /// Called on the main thread when a track finished playing naturally.
    var onFinished: (() -> Void)?
    /// Extra time (s) the lights are ahead of the audio, to compensate for DMX/fixture latency.
    var lookahead: Double = 0.04

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        engine.prepare()
    }

    var isPlaying: Bool { state.get().playing }

    var currentTime: Double {
        let s = state.get()
        guard s.playing else { return s.pausedAt }
        guard let nodeTime = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nodeTime),
              let file = s.file else { return s.segmentStart }
        let latency = engine.outputNode.presentationLatency
        return s.segmentStart + Double(pt.sampleTime) / file.processingFormat.sampleRate - latency
    }

    var duration: Double {
        guard let f = state.get().file else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    func load(track: SetlistTrack) throws {
        stop()
        let file = try AVAudioFile(forReading: track.url)
        state.mutate {
            $0.file = file
            $0.source = track.analysis.map { TrackMusicSource(analysis: $0) }
            $0.pausedAt = 0
            $0.segmentStart = 0
        }
    }

    func updateAnalysis(_ a: TrackAnalysis?) {
        state.mutate { $0.source = a.map { TrackMusicSource(analysis: $0) } }
    }

    func play(from time: Double? = nil) throws {
        guard let file = state.get().file else { return }
        if !engine.isRunning { try engine.start() }
        let sr = file.processingFormat.sampleRate
        let start = clamp(time ?? state.get().pausedAt, 0, max(0, Double(file.length) / sr - 0.05))
        player.stop()
        let startFrame = AVAudioFramePosition(start * sr)
        let frames = AVAudioFrameCount(max(0, file.length - startFrame))
        guard frames > 0 else { return }
        let gen = state.mutate { s -> Int in
            s.generation += 1
            s.segmentStart = start
            s.playing = true
            return s.generation
        }
        // Prepare a fresh analyser for kick/band detection on the playing audio.
        tapAnalyzer.set(LiveAnalyzer(sampleRate: engine.mainMixerNode.outputFormat(forBus: 0).sampleRate))
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let s = self.state.get()
                // Only treat it as finished if this is still the active segment and we weren't stopped.
                if s.generation == gen && s.playing {
                    self.state.mutate { $0.playing = false; $0.pausedAt = 0 }
                    self.onFinished?()
                }
            }
        }
        player.play()
    }

    func pause() {
        let t = currentTime
        state.mutate { $0.playing = false; $0.pausedAt = t; $0.generation += 1 }
        player.stop()
    }

    func stop() {
        state.mutate { $0.playing = false; $0.pausedAt = 0; $0.generation += 1 }
        player.stop()
    }

    func seek(to time: Double) throws {
        if isPlaying { try play(from: time) } else { state.mutate { $0.pausedAt = time } }
    }

    /// Called from the DMX output thread.
    func musicState(now: Double) -> MusicState {
        let s = state.get()
        let t = currentTime
        var m: MusicState
        if let src = s.source {
            m = src.state(atPlaybackTime: t, now: now, lookahead: lookahead, isPlaying: s.playing)
        } else if let la = tapAnalyzer.get(), s.playing {
            // Not analysed yet: fall back to real-time analysis of the playing audio.
            m = la.state
        } else {
            m = MusicState()
        }
        if let live = tapAnalyzer.get()?.state, s.playing {
            m.kickCount = live.kickCount
            m.snareCount = live.snareCount
            m.hatCount = live.hatCount
            m.bass = live.bass; m.lowMid = live.lowMid; m.mid = live.mid; m.high = live.high
        }
        return m
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chans = Int(buffer.format.channelCount)
        if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
        var peak: Float = 0
        for i in 0..<frames {
            var v: Float = 0
            for c in 0..<chans { v += data[c][i] }
            v /= Float(max(chans, 1))
            mono[i] = v
            peak = max(peak, abs(v))
        }
        level.set(max(peak, level.get() * 0.8))
        if state.get().playing {
            tapAnalyzer.get()?.process(mono, now: ProcessInfo.processInfo.systemUptime)
        }
    }
}
