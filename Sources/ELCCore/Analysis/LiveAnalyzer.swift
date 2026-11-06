import Foundation

/// Tracks loudness relative to the recent history so the engine gets a stable 0...1 "energy".
struct EnergyTracker {
    var dbFast = -80.0
    var dbSlow = -80.0
    var peakDb = -30.0
    var history: [Double] = []
    var historyTimer = 0.0
    var bassShort = 0.0
    var bassLong = 1e-4
    var bandMax: [Double] = [1e-4, 1e-4, 1e-4, 1e-4]
    var bandLevels: [Double] = [0, 0, 0, 0]
    var silentFor = 0.0
    var energy = 0.0
    var dynamicRange = 18.0

    mutating func update(_ f: FrameFeatures, dt: Double) {
        dbFast = smoothTowards(dbFast, f.rmsDb, dt: dt, timeConstant: 0.25)
        dbSlow = smoothTowards(dbSlow, f.rmsDb, dt: dt, timeConstant: 3)
        peakDb = max(dbFast, peakDb - 0.12 * dt)
        historyTimer += dt
        if historyTimer >= 0.1 {
            historyTimer = 0
            if dbFast > -60 {
                history.append(dbFast)
                if history.count > 600 { history.removeFirst(history.count - 600) }
            }
        }
        let rank: Double
        if history.count > 20 {
            var below = 0
            for v in history where v < dbFast { below += 1 }
            rank = Double(below) / Double(history.count)
        } else {
            rank = 0.5
        }
        let absNorm = clamp((dbFast - (peakDb - dynamicRange)) / dynamicRange, 0, 1)
        bassShort = smoothTowards(bassShort, f.bands[0], dt: dt, timeConstant: 0.4)
        bassLong = smoothTowards(bassLong, max(f.bands[0], 1e-6), dt: dt, timeConstant: 20)
        let bassPresence = clamp(bassShort / max(bassLong, 1e-6) / 1.6, 0, 1)
        for i in 0..<4 {
            bandMax[i] = max(f.bands[i], bandMax[i] * exp(-dt / 6))
            let lvl = clamp(f.bands[i] / max(bandMax[i], 1e-6), 0, 1)
            bandLevels[i] = max(lvl, bandLevels[i] * exp(-dt / 0.12))
        }
        let target = clamp(0.45 * absNorm + 0.35 * rank + 0.2 * bassPresence, 0, 1)
        energy = smoothTowards(energy, target, dt: dt, timeConstant: 0.35)
        if f.rmsDb < -52 { silentFor += dt } else { silentFor = 0 }
    }

    var bassPresence: Double { clamp(bassShort / max(bassLong, 1e-6), 0, 3) }
    var isSilent: Bool { silentFor > 1.5 }
}

/// Classifies the live signal into musical sections using short/long term energy and bass.
struct SectionDetector {
    var section: MusicSection = .silence
    var dwell = 0.0
    var eShort = 0.0
    var eLong = 0.0
    var bassShort = 1.0
    var trend: [Double] = []
    var trendTimer = 0.0
    var lowBefore = false
    var changedAtBeat = 0.0

    mutating func update(energy: Double, bassPresence: Double, silent: Bool, dt: Double, beat: Double) -> Bool {
        eShort = smoothTowards(eShort, energy, dt: dt, timeConstant: 1.5)
        eLong = smoothTowards(eLong, energy, dt: dt, timeConstant: 14)
        bassShort = smoothTowards(bassShort, bassPresence, dt: dt, timeConstant: 0.6)
        trendTimer += dt
        if trendTimer >= 0.25 {
            trendTimer = 0
            trend.append(eShort)
            if trend.count > 24 { trend.removeFirst() }  // 6 seconds
        }
        dwell += dt
        let slope: Double = trend.count >= 12 ? (trend.last! - trend[trend.count - 12]) : 0  // change over 3 s
        var next = section
        if silent {
            next = .silence
        } else {
            switch section {
            case .silence:
                next = eShort < 0.3 ? .ambient : .groove
            case .breakdown, .build, .ambient:
                if bassShort > 0.85 && energy > max(0.55, eLong + 0.12) && dwell > 2 {
                    next = .drop
                } else if section != .build && slope > 0.12 && eShort > 0.3 && dwell > 3 {
                    next = .build
                } else if section == .build && slope < -0.15 && dwell > 4 {
                    next = .breakdown
                } else if section == .ambient && eShort > 0.45 && bassShort > 0.7 && dwell > 3 {
                    next = .groove
                }
            case .drop:
                if dwell > 20 { next = eShort > 0.72 ? .peak : .groove }
                else if bassShort < 0.4 && dwell > 6 { next = .breakdown }
            case .groove, .peak:
                if eShort < 0.22 && dwell > 4 { next = .ambient }
                else if bassShort < 0.45 && eShort < max(0.6, eLong) && dwell > 4 { next = .breakdown }
                else if section == .groove && eShort > 0.75 && dwell > 6 { next = .peak }
                else if section == .peak && eShort < 0.6 && dwell > 6 { next = .groove }
                else if section == .groove && slope > 0.18 && dwell > 6 { next = .build }
            }
        }
        if next != section {
            section = next
            dwell = 0
            changedAtBeat = beat
            return true
        }
        return false
    }
}

/// Real time analyser for the live audio input: tempo, beat phase, kicks/snares/hats,
/// energy and section. Feed it mono audio from the audio thread; read `state` from anywhere.
public final class LiveAnalyzer: @unchecked Sendable {
    public struct Config: Sendable {
        public var minBPM: Double = 75
        public var maxBPM: Double = 180
        public var preferredBPM: Double = 124
        /// Seconds to shift beats earlier to compensate for audio input + DMX latency.
        public var latencyCompensation: Double = 0.06
        public init() {}
    }

    public var config = Config()
    public let sampleRate: Double
    private let extractor: FeatureExtractor
    private let fps: Double
    private var onsetHistory: [Double] = []
    private let historyLength: Int
    private var tempoTimer = 0.0
    private var bpm = 120.0
    private var tempoConfidence = 0.0
    private var candidateBPM = 0.0
    private var candidateCount = 0
    private var beatPos = 0.0
    private var oPrev2 = 0.0, oPrev1 = 0.0
    private var oMean = 0.0, oVar = 0.01
    private var fluxMean = [Double](repeating: 0, count: 4)
    private var fluxVar = [Double](repeating: 0.01, count: 4)
    private var fluxPrev = [Double](repeating: 0, count: 4)
    private var lastHit = [Double](repeating: -1, count: 4)
    private var kickCount = 0, snareCount = 0, hatCount = 0
    private var accentAcc = [Double](repeating: 0, count: 4)
    private var downbeatOffset = 0
    private var currentBeatIndex = 0
    private var currentAccent = 0.0
    private var energy = EnergyTracker()
    private var sections = SectionDetector()
    private var audioTime = 0.0
    private var vibeAcc = VibeAccumulator(timeConstant: 20)
    private var vibeTimer = 0.0
    private var vibe = Vibe()
    private let evidenceBox = Locked<[SoundEvidence: Double]>([:])
    private let stateBox = Locked(MusicState())

    private let manualBox = Locked<Double?>(nil)
    private let commands = Locked<[(LiveAnalyzer) -> Void]>([])

    /// Tap tempo / manual tempo lock. When set, tempo detection is bypassed (phase still follows the music).
    public var manualBPM: Double? {
        get { manualBox.get() }
        set { manualBox.set(newValue) }
    }

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        extractor = FeatureExtractor(sampleRate: sampleRate)
        fps = extractor.framesPerSecond
        historyLength = Int(8 * fps)
    }

    public var state: MusicState { stateBox.get() }

    /// Process a buffer of mono samples. `now` is the monotonic time at the end of the buffer.
    public func process(_ samples: UnsafeBufferPointer<Float>, now: Double) {
        let pending = commands.mutate { list -> [(LiveAnalyzer) -> Void] in
            let l = list; list.removeAll(); return l
        }
        for c in pending { c(self) }
        extractor.process(samples) { f in self.handle(f) }
        publish(now: now)
    }

    public func process(_ samples: [Float], now: Double) {
        samples.withUnsafeBufferPointer { process($0, now: now) }
    }

    /// Re-align the bar so that the current beat is "the one" (UI button).
    public func markDownbeat() {
        commands.mutate { $0.append { $0.applyMarkDownbeat() } }
    }

    /// Nudge the beat phase (in beats, e.g. ±0.05).
    public func nudge(_ beats: Double) {
        commands.mutate { $0.append { $0.beatPos += beats } }
    }

    /// Instrument/vocal evidence from the on-device sound classifier (any thread).
    public func updateSoundEvidence(_ e: [SoundEvidence: Double]) { evidenceBox.set(e) }

    private func applyMarkDownbeat() {
        downbeatOffset = ((Int(beatPos.rounded()) % 4) + 4) % 4
        accentAcc = [0, 0, 0, 0]
        accentAcc[downbeatOffset] = 5
    }

    private func handle(_ f: FrameFeatures) {
        let dt = 1 / fps
        audioTime = f.time
        energy.update(f, dt: dt)

        // --- onset history + tempo
        onsetHistory.append(f.onset)
        if onsetHistory.count > historyLength { onsetHistory.removeFirst(onsetHistory.count - historyLength) }
        tempoTimer += dt
        if tempoTimer >= 0.5 {
            tempoTimer = 0
            updateTempo()
        }

        // --- beat phase (PLL)
        beatPos += dt * bpm / 60
        oMean = smoothTowards(oMean, f.onset, dt: dt, timeConstant: 1.0)
        let dev = f.onset - oMean
        oVar = smoothTowards(oVar, dev * dev, dt: dt, timeConstant: 1.0)
        let std = max(oVar.squareRoot(), 1e-6)
        if oPrev1 > oPrev2 && oPrev1 >= f.onset && oPrev1 > oMean + 0.8 * std && !energy.isSilent {
            let peakPos = beatPos - dt * bpm / 60
            let err = peakPos - peakPos.rounded()
            if abs(err) < 0.3 {
                let strength = clamp((oPrev1 - oMean) / (3 * std), 0, 1)
                let gain = 0.06 + 0.2 * (1 - tempoConfidence)
                beatPos -= err * gain * strength
            }
        }
        oPrev2 = oPrev1; oPrev1 = f.onset

        // --- kick / snare / hat hits
        for band in [0, 2, 3] {
            let v = f.flux[band]
            fluxMean[band] = smoothTowards(fluxMean[band], v, dt: dt, timeConstant: 0.8)
            let d = v - fluxMean[band]
            fluxVar[band] = smoothTowards(fluxVar[band], d * d, dt: dt, timeConstant: 0.8)
            let thr = fluxMean[band] + 1.4 * max(fluxVar[band].squareRoot(), 1e-6)
            let minGap = band == 3 ? 0.08 : 0.16
            if v > thr && fluxPrev[band] <= thr && f.time - lastHit[band] > minGap && !energy.isSilent {
                lastHit[band] = f.time
                switch band {
                case 0: kickCount &+= 1
                case 2: snareCount &+= 1
                default: hatCount &+= 1
                }
            }
            fluxPrev[band] = v
        }

        // --- downbeat estimation: accumulate accents around each beat
        let nearest = Int(beatPos.rounded())
        if nearest != currentBeatIndex {
            let slot = ((currentBeatIndex % 4) + 4) % 4
            for i in 0..<4 { accentAcc[i] *= 0.985 }
            accentAcc[slot] += currentAccent
            currentAccent = 0
            currentBeatIndex = nearest
            if let best = accentAcc.indices.max(by: { accentAcc[$0] < accentAcc[$1] }),
               best != downbeatOffset, accentAcc[best] > accentAcc[downbeatOffset] * 1.25 {
                downbeatOffset = best
            }
        }
        if abs(beatPos - beatPos.rounded()) < 0.15 {
            currentAccent = max(currentAccent, f.flux[0] + 0.8 * f.flux[3])
        }

        // --- vibe (style / mood), slow sliding window
        vibeAcc.add(f, dt: dt, beatPosition: tempoConfidence > 0.15 ? beatPos : nil, downbeatOffset: downbeatOffset)
        vibeTimer += dt
        if vibeTimer >= 2 {
            vibeTimer = 0
            if vibeAcc.hasData && f.time > 8 {
                let feats = vibeAcc.features(bpm: bpm, pulseClarity: tempoConfidence, evidence: evidenceBox.get())
                vibe = VibeModel.infer(feats)
            }
        }

        // --- sections
        _ = sections.update(energy: energy.energy, bassPresence: energy.bassPresence,
                            silent: energy.isSilent, dt: dt, beat: beatPos)
        if sections.section == .drop && sections.dwell < dt * 1.5 {
            // A drop almost always lands on "the one": re-align the bar.
            downbeatOffset = ((nearest % 4) + 4) % 4
        }
    }

    private func updateTempo() {
        if let m = manualBox.get() {
            bpm = m
            tempoConfidence = 1
            return
        }
        guard let est = TempoEstimator.estimate(onsets: onsetHistory, fps: fps, minBPM: config.minBPM,
                                                maxBPM: config.maxBPM, preferredBPM: config.preferredBPM) else { return }
        let cand = est.bpm
        tempoConfidence = smoothTowards(tempoConfidence, est.confidence, dt: 0.5, timeConstant: 2)
        let ratio = cand / bpm
        if abs(ratio - 1) < 0.04 {
            bpm += (cand - bpm) * 0.25
            candidateCount = 0
        } else {
            let octave = abs(ratio - 2) < 0.08 || abs(ratio - 0.5) < 0.04 || abs(ratio - 1.5) < 0.06 || abs(ratio - 0.667) < 0.04
            if abs(cand / max(candidateBPM, 1) - 1) < 0.04 { candidateCount += 1 } else { candidateBPM = cand; candidateCount = 1 }
            let needed = octave ? 10 : 4
            if candidateCount >= needed || tempoConfidence < 0.05 {
                bpm = candidateBPM
                candidateCount = 0
            }
        }
        bpm = clamp(bpm, config.minBPM, config.maxBPM)
    }

    private func publish(now: Double) {
        var s = MusicState()
        s.source = .live
        s.timestamp = now
        s.bpm = bpm
        s.beatPosition = beatPos + config.latencyCompensation * bpm / 60
        s.downbeatOffset = downbeatOffset
        s.energy = energy.energy
        s.bass = energy.bandLevels[0]
        s.lowMid = energy.bandLevels[1]
        s.mid = energy.bandLevels[2]
        s.high = energy.bandLevels[3]
        s.kickCount = kickCount
        s.snareCount = snareCount
        s.hatCount = hatCount
        s.section = sections.section
        s.sectionStartBeat = sections.changedAtBeat
        s.tempoConfidence = tempoConfidence
        s.isSilent = energy.isSilent
        s.vibe = vibe
        stateBox.set(s)
    }
}
