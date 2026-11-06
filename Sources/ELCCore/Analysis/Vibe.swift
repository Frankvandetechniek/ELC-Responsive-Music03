import Foundation

/// Musical style families the lighting adapts to.
public enum MusicStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case ambient = "Ambient / Chill"
    case ballad = "Ballad / Acoustic"
    case pop = "Pop"
    case rock = "Rock / Live band"
    case hipHop = "Hip-hop / R&B"
    case house = "House / Techno"
    case edm = "EDM / Festival"
    case drumAndBass = "Drum & Bass"
    case latin = "Latin / Afro"
    public var id: String { rawValue }
}

/// The "vibe" of the music: style plus mood on the arousal (calm ↔ energetic)
/// and valence (dark/sad ↔ bright/happy) axes.
public struct Vibe: Codable, Equatable, Sendable {
    public var style: MusicStyle = .pop
    public var styleConfidence: Double = 0
    public var arousal: Double = 0.5
    public var valence: Double = 0.5
    public var key: String = ""
    public var descriptors: [String] = []
    public var scores: [String: Double] = [:]
    public var isReady: Bool = false
    /// Strongest MusiCNN tags with probabilities (for display).
    public var topTags: [String] = []
    /// True when the neural genre/mood model contributed.
    public var usesNeuralModel: Bool = false
    /// How "electronic / dance" the music is (0...1), from the neural tags.
    public var electronic: Double = 0

    public init() {}

    /// A human word for the mood quadrant.
    public var moodWord: String {
        switch (arousal >= 0.5, valence >= 0.5) {
        case (true, true): return arousal > 0.75 ? "Euphoric" : "Upbeat"
        case (true, false): return arousal > 0.75 ? "Intense" : "Dark & driving"
        case (false, true): return arousal < 0.25 ? "Dreamy" : "Warm"
        case (false, false): return arousal < 0.25 ? "Melancholic" : "Moody"
        }
    }
}

/// Groups of Apple SoundAnalysis (built-in classifier, `.version1`) labels used as instrument/vocal evidence.
public enum SoundEvidence: String, CaseIterable, Codable, Sendable {
    case vocals, rap, electricGuitar, acoustic, piano, organ, strings, brass, synth, drums, latinPercussion, scratching, crowd

    public static let labels: [SoundEvidence: [String]] = [
        .vocals: ["singing", "choir_singing", "humming", "yodeling"],
        .rap: ["rapping"],
        .electricGuitar: ["electric_guitar", "steel_guitar_slide_guitar"],
        .acoustic: ["acoustic_guitar", "guitar_strum", "ukulele", "banjo", "mandolin", "plucked_string_instrument", "harp"],
        .piano: ["piano", "electric_piano", "keyboard_musical"],
        .organ: ["organ", "hammond_organ", "electronic_organ"],
        .strings: ["bowed_string_instrument", "violin_fiddle", "cello", "orchestra", "double_bass", "timpani"],
        .brass: ["brass_instrument", "trumpet", "trombone", "saxophone", "french_horn", "wind_instrument", "flute", "clarinet"],
        .synth: ["synthesizer"],
        .drums: ["drum_kit", "drum", "snare_drum", "bass_drum", "hi_hat", "cymbal"],
        .latinPercussion: ["percussion", "cowbell", "tambourine", "marimba_xylophone", "steelpan", "tabla", "mallet_percussion", "rattle_instrument"],
        .scratching: ["disc_scratching"],
        .crowd: ["cheering", "crowd", "applause"],
    ]

    /// All classifier labels we care about (to filter results cheaply).
    public static let allLabels: Set<String> = Set(labels.values.flatMap { $0 })

    /// Converts raw classifier confidences (label → 0...1) into evidence strengths (max per group).
    public static func evidence(from classes: [String: Double]) -> [SoundEvidence: Double] {
        var out: [SoundEvidence: Double] = [:]
        for (group, names) in labels {
            out[group] = names.map { classes[$0] ?? 0 }.max() ?? 0
        }
        return out
    }
}

/// Audio descriptors over a time window. Computed from frame features + beat positions.
public struct VibeFeatures: Codable, Equatable, Sendable {
    public var bpm: Double = 120
    public var pulseClarity: Double = 0     // tempo confidence 0...1
    public var onsetRate: Double = 0        // onsets / second
    public var fourOnFloor: Double = 0      // kick on every beat 0...1
    public var backbeat: Double = 0         // snare on 2 & 4 0...1
    public var syncopation: Double = 0      // energy between the beats 0...1
    public var brightness: Double = 0       // 0...1 (spectral centroid)
    public var bassShare: Double = 0        // 0...1
    public var dynamics: Double = 0         // loudness variation 0...1
    public var percussiveness: Double = 0   // 0...1
    public var majorness: Double = 0        // -1 (minor) ... 1 (major)
    public var tonalClarity: Double = 0     // 0...1
    public var key: String = ""
    public var evidence: [String: Double] = [:]   // SoundEvidence rawValue → 0...1
    /// MusiCNN (MSD) tag probabilities, e.g. "pop" → 0.62 (empty when not available).
    public var tags: [String: Double] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case bpm, pulseClarity, onsetRate, fourOnFloor, backbeat, syncopation, brightness, bassShare, dynamics,
             percussiveness, majorness, tonalClarity, key, evidence, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? 120
        pulseClarity = try c.decodeIfPresent(Double.self, forKey: .pulseClarity) ?? 0
        onsetRate = try c.decodeIfPresent(Double.self, forKey: .onsetRate) ?? 0
        fourOnFloor = try c.decodeIfPresent(Double.self, forKey: .fourOnFloor) ?? 0
        backbeat = try c.decodeIfPresent(Double.self, forKey: .backbeat) ?? 0
        syncopation = try c.decodeIfPresent(Double.self, forKey: .syncopation) ?? 0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        bassShare = try c.decodeIfPresent(Double.self, forKey: .bassShare) ?? 0
        dynamics = try c.decodeIfPresent(Double.self, forKey: .dynamics) ?? 0
        percussiveness = try c.decodeIfPresent(Double.self, forKey: .percussiveness) ?? 0
        majorness = try c.decodeIfPresent(Double.self, forKey: .majorness) ?? 0
        tonalClarity = try c.decodeIfPresent(Double.self, forKey: .tonalClarity) ?? 0
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        evidence = try c.decodeIfPresent([String: Double].self, forKey: .evidence) ?? [:]
        tags = try c.decodeIfPresent([String: Double].self, forKey: .tags) ?? [:]
    }

    func ev(_ e: SoundEvidence) -> Double { evidence[e.rawValue] ?? 0 }
}

/// Accumulates frame-level features into `VibeFeatures`. With `timeConstant` it is a
/// sliding (exponential) window for live use; without, a plain average for whole tracks.
public struct VibeAccumulator: Sendable {
    public var timeConstant: Double?
    private var weightSum = 0.0
    private var chroma = [Double](repeating: 0, count: 12)
    private var centroid = 0.0
    private var bandMeans = [Double](repeating: 0, count: 4)
    private var loud = 0.0, loudSq = 0.0
    private var onBeatKick = [Double](repeating: 0, count: 4)
    private var offBeatKick = 0.0
    private var snareOn24 = 0.0, snareOn13 = 0.0
    private var offEighth = 0.0, onBeatAll = 0.0
    private var onsetMean = 0.0
    private var peakCount = 0.0
    private var lastOnset = 0.0, lastOnset2 = 0.0
    private var onsetAvg = 0.0, onsetVar = 0.01
    private var elapsed = 0.0

    public init(timeConstant: Double?) { self.timeConstant = timeConstant }

    public mutating func add(_ f: FrameFeatures, dt: Double, beatPosition: Double?, downbeatOffset: Int) {
        guard f.rmsDb > -50 else { return }
        elapsed += dt
        // decay factor for the sliding window
        let k: Double
        if let tc = timeConstant { k = exp(-dt / tc) } else { k = 1 }
        func acc(_ v: inout Double, _ x: Double) { v = v * k + x * dt }
        func accA(_ v: inout [Double], _ i: Int, _ x: Double) { v[i] = v[i] * k + x * dt }
        weightSum = weightSum * k + dt
        for i in 0..<12 { accA(&chroma, i, f.chroma[i]) }
        acc(&centroid, f.centroid)
        for i in 0..<4 { accA(&bandMeans, i, f.bands[i]) }
        acc(&loud, f.rmsDb)
        acc(&loudSq, f.rmsDb * f.rmsDb)
        acc(&onsetMean, f.onset)
        // onset peak counting
        onsetAvg = smoothTowards(onsetAvg, f.onset, dt: dt, timeConstant: 1)
        let d = f.onset - onsetAvg
        onsetVar = smoothTowards(onsetVar, d * d, dt: dt, timeConstant: 1)
        // Absolute floor (0.3) so steady tones/pads don't count as onsets (drum hits are ~1-6, pads ~0.03).
        let isPeak = lastOnset > lastOnset2 && lastOnset >= f.onset && lastOnset > 0.3
            && lastOnset > onsetAvg + 0.7 * onsetVar.squareRoot()
        peakCount = peakCount * k + (isPeak ? 1 : 0)
        lastOnset2 = lastOnset; lastOnset = f.onset
        // rhythm relative to the beat grid
        if let b = beatPosition {
            let frac = fmodPositive(b, 1)
            let beatIdx = Int(floor(fmodPositive(b - Double(downbeatOffset), 4)))
            let kick = f.flux[0], snare = f.flux[2], hats = f.flux[3]
            if frac < 0.12 || frac > 0.92 {
                accA(&onBeatKick, beatIdx, kick)
                acc(&onBeatAll, kick + snare + hats)
                if frac < 0.12 {
                    if beatIdx % 2 == 1 { acc(&snareOn24, snare) } else { acc(&snareOn13, snare) }
                }
            } else if (frac > 0.38 && frac < 0.62) || (frac > 0.2 && frac < 0.3) || (frac > 0.7 && frac < 0.8) {
                acc(&offBeatKick, kick)
                acc(&offEighth, snare + hats + kick)
            }
        }
    }

    public var hasData: Bool { weightSum > 3 }

    public func features(bpm: Double, pulseClarity: Double, evidence: [SoundEvidence: Double]) -> VibeFeatures {
        var v = VibeFeatures()
        v.bpm = bpm
        v.pulseClarity = clamp(pulseClarity, 0, 1)
        let w = max(weightSum, 1e-6)
        v.onsetRate = peakCount / w
        // Four on the floor: strong kick on each of the 4 beats, little kick between them.
        let beats = onBeatKick
        let maxB = beats.max() ?? 0, minB = beats.min() ?? 0
        let evenness = maxB > 1e-9 ? minB / maxB : 0
        let onAvg = beats.reduce(0, +) / 4
        let ratio = onAvg / max(onAvg + offBeatKick * 1.0, 1e-9)
        v.fourOnFloor = clamp((ratio - 0.5) * 2.2, 0, 1) * clamp((evenness - 0.35) / 0.5, 0, 1)
        v.backbeat = clamp((snareOn24 / max(snareOn24 + snareOn13, 1e-9) - 0.5) * 3, 0, 1)
        v.syncopation = clamp((offEighth / max(offEighth + onBeatAll, 1e-9)) * 2 - 0.4, 0, 1)
        v.brightness = clamp((centroid / w) / 4500, 0, 1)
        let bandTotal = bandMeans.reduce(0, +)
        v.bassShare = bandTotal > 0 ? clamp(bandMeans[0] / bandTotal, 0, 1) : 0
        let lm = loud / w
        v.dynamics = clamp(max(0, loudSq / w - lm * lm).squareRoot() / 9, 0, 1)
        // Mean onset strength in absolute terms: sustained pads ≈ 0.02, drum-driven mixes ≈ 0.3-1.
        v.percussiveness = clamp((onsetMean / w) / 0.5, 0, 1)
        let c = chroma.map { $0 / w }
        let key = KeyFinder.estimate(chroma: c)
        v.majorness = key.majorness
        v.tonalClarity = key.clarity
        v.key = key.name
        for (e, x) in evidence { v.evidence[e.rawValue] = x }
        return v
    }
}

enum KeyFinder {
    // Krumhansl-Kessler key profiles
    static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<12 {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 1e-12 && db > 1e-12 ? num / (da * db).squareRoot() : 0
    }

    static func estimate(chroma: [Double]) -> (name: String, majorness: Double, clarity: Double) {
        guard chroma.reduce(0, +) > 1e-9 else { return ("", 0, 0) }
        var bestMaj = -2.0, bestMin = -2.0, majKey = 0, minKey = 0
        for r in 0..<12 {
            let rotated = (0..<12).map { chroma[($0 + r) % 12] }
            let cm = correlation(rotated, major), cn = correlation(rotated, minor)
            if cm > bestMaj { bestMaj = cm; majKey = r }
            if cn > bestMin { bestMin = cn; minKey = r }
        }
        let isMajor = bestMaj >= bestMin
        let name = isMajor ? "\(names[majKey]) major" : "\(names[minKey]) minor"
        return (name, clamp((bestMaj - bestMin) * 4, -1, 1), clamp(max(bestMaj, bestMin), 0, 1))
    }
}

/// Small interpretable model that turns `VibeFeatures` into a `Vibe`.
/// Arousal/valence follow the circumplex model of affect used in music-emotion research
/// (tempo, rhythmic density, brightness → arousal; mode, brightness, tempo → valence).
/// Style is a softmax over prototype scores combining rhythm features with instrument/vocal
/// evidence from Apple's on-device neural sound classifier.
public enum VibeModel {
    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }
    static func logit(_ p: Double) -> Double { let q = clamp(p, 1e-4, 1 - 1e-4); return log(q / (1 - q)) }
    static func bump(_ x: Double, _ c: Double, _ w: Double) -> Double { exp(-0.5 * pow((x - c) / w, 2)) }
    /// Tempo fit allowing for half/double tempo detections.
    static func tempoFit(_ bpm: Double, _ c: Double, _ w: Double) -> Double {
        max(bump(bpm, c, w), 0.8 * bump(bpm * 2, c, w), 0.8 * bump(bpm / 2, c, w))
    }

    public static func infer(_ f: VibeFeatures) -> Vibe {
        var v = Vibe()
        v.isReady = true
        v.key = f.key
        let tempoN = (f.bpm - 115) / 35
        let onsetN = (f.onsetRate - 3) / 2.5
        let brightN = (f.brightness - 0.35) / 0.15
        let percN = (f.percussiveness - 0.45) / 0.25

        let ev = { (e: SoundEvidence) in f.ev(e) }
        let acousticish = max(ev(.acoustic), ev(.piano), ev(.strings))

        v.arousal = sigmoid(0.9 * tempoN + 0.9 * onsetN + 0.7 * brightN + 0.6 * percN
                            + 0.8 * (f.fourOnFloor - 0.4) + 0.6 * (ev(.drums) - 0.3)
                            - 1.0 * acousticish * (1 - f.fourOnFloor) - 0.4 * (f.dynamics - 0.3))
        v.valence = sigmoid(1.6 * f.majorness * max(0.3, f.tonalClarity) + 0.5 * brightN + 0.35 * tempoN
                            + 0.6 * f.syncopation + 0.3 * ev(.brass) + 0.3 * ev(.latinPercussion)
                            - 0.4 * (f.bassShare - 0.35) / 0.15 * 0.5)

        let lowPulse = 1 - f.pulseClarity
        var s: [MusicStyle: Double] = [:]
        s[.house] = 2.6 * f.fourOnFloor + 1.4 * tempoFit(f.bpm, 124, 6) + 0.8 * ev(.synth)
            + 0.4 * f.bassShare / 0.4 - 0.8 * ev(.electricGuitar) - 0.6 * acousticish - 0.4 * f.dynamics
        s[.edm] = 1.6 * f.fourOnFloor + 1.2 * max(tempoFit(f.bpm, 128, 5), tempoFit(f.bpm, 150, 8))
            + 1.0 * f.brightness / 0.5 + 1.4 * f.dynamics / 0.5 + 0.8 * ev(.synth) + 0.3 * ev(.vocals) - 0.6 * ev(.electricGuitar)
        // ~87 BPM readings are ambiguous (hip-hop vs half-time DnB): dense 16th hats decide.
        let dnbTempo = max(bump(f.bpm, 172, 9), bump(f.bpm * 2, 172, 9) * clamp((f.onsetRate - 3) / 3, 0, 1))
        s[.drumAndBass] = 3.0 * dnbTempo
            + 1.2 * f.syncopation + 0.8 * f.bassShare / 0.4 - 1.2 * f.fourOnFloor - 0.5 * acousticish
        s[.hipHop] = 1.6 * max(tempoFit(f.bpm, 90, 12), tempoFit(f.bpm, 140, 6) * 0.8) + 1.2 * f.backbeat
            + 1.0 * f.bassShare / 0.4 + 2.2 * ev(.rap) + 0.8 * ev(.scratching) + 0.6 * f.syncopation - 1.3 * f.fourOnFloor
        s[.rock] = 2.6 * ev(.electricGuitar) + 1.4 * f.backbeat + 1.0 * ev(.drums) + 0.5 * tempoFit(f.bpm, 125, 30)
            + 0.4 * ev(.organ) - 0.9 * ev(.synth) - 0.6 * f.fourOnFloor
        s[.pop] = 1.4 * ev(.vocals) + 0.8 * f.backbeat + 0.8 * tempoFit(f.bpm, 112, 18) + 0.8 * max(0, f.majorness)
            + 0.4 * f.fourOnFloor + 0.3 * ev(.synth) + 0.4 * ev(.piano) + 0.6
        s[.ballad] = 1.6 * bump(f.bpm, 76, 16) + 1.4 * (1 - f.percussiveness) + 1.6 * acousticish + 0.6 * ev(.vocals)
            - 1.2 * f.fourOnFloor - 0.8 * f.onsetRate / 4
        s[.ambient] = 2.0 * lowPulse + 1.4 * max(0, 1 - f.onsetRate / 3) + 1.4 * (1 - f.percussiveness)
            + 0.5 * ev(.synth) - 1.0 * f.fourOnFloor - 1.2 * ev(.drums) - 0.6 * ev(.vocals)
        s[.latin] = 1.8 * f.syncopation + 1.0 * tempoFit(f.bpm, 98, 10) + 1.8 * ev(.latinPercussion) + 0.6 * ev(.brass)
            + 0.4 * max(0, f.majorness) - 0.3 * ev(.electricGuitar)

        // Neural genre / mood tags (MusiCNN, trained on the Million Song Dataset) dominate when available;
        // the rhythm rules above then only break ties (e.g. house vs EDM, DnB tempo, Latin percussion).
        if !f.tags.isEmpty {
            v.usesNeuralModel = true
            let g = { (k: String) in f.tags[k] ?? 0 }
            var ml: [MusicStyle: Double] = [:]
            ml[.pop] = g("pop") + 0.6 * g("indie pop") + 0.4 * g("catchy") + 0.25 * g("female vocalists") + 0.2 * g("00s")
            ml[.rock] = g("rock") + g("alternative rock") + g("classic rock") + g("indie rock") + g("hard rock")
                + g("metal") + g("heavy metal") + g("punk") + g("Progressive rock") + 0.4 * g("guitar") + 0.3 * g("alternative")
            ml[.hipHop] = 1.2 * g("Hip-Hop") + g("rnb") + 0.4 * g("soul") + 0.3 * g("funk") + 0.3 * g("sexy")
            ml[.house] = 1.3 * g("House") + 0.4 * g("electronic") + 0.3 * g("electro") + 0.3 * g("dance")
            ml[.edm] = g("dance") + 0.8 * g("electro") + 0.4 * g("electronic") + 0.5 * g("party") + 0.2 * g("electronica")
            ml[.ambient] = g("ambient") + 0.7 * g("chillout") + 0.6 * g("chill") + 0.4 * g("instrumental")
                + 0.3 * g("electronica") + 0.3 * g("experimental")
            ml[.ballad] = g("acoustic") + 0.8 * g("folk") + 0.7 * g("Mellow") + 0.5 * g("beautiful") + 0.5 * g("sad")
                + 0.5 * g("easy listening") + 0.5 * g("country") + 0.4 * g("jazz") + 0.3 * g("blues")
            ml[.drumAndBass] = 0.4 * g("electronic") * dnbTempo
            ml[.latin] = 0.3 * g("dance") * (f.syncopation + ev(.latinPercussion))
            let mlMax = max(ml.values.max() ?? 0, 1e-6)
            for style in MusicStyle.allCases {
                // relative (which style the tags favour) + absolute (how sure the model is)
                let rel = (ml[style] ?? 0) / mlMax
                s[style] = 0.35 * (s[style] ?? 0) + 4.0 * rel + 2.0 * (ml[style] ?? 0)
            }
            // Mood from tags
            let happy = g("happy") + 0.5 * g("catchy") + 0.5 * g("party") + 0.3 * g("dance")
            let sad = g("sad") + 0.4 * g("Mellow") + 0.2 * g("beautiful")
            v.valence = sigmoid(logit(v.valence) * 0.5 + 3.0 * (happy - sad))
            let energetic = g("party") + g("dance") + g("metal") + g("hard rock") + g("punk") + g("heavy metal") + 0.5 * g("electro")
            let calm = g("Mellow") + g("chill") + g("chillout") + g("ambient") + 0.6 * g("acoustic") + g("easy listening") + 0.4 * g("sad")
            v.arousal = sigmoid(logit(v.arousal) * 0.5 + 2.5 * (energetic - calm))
            v.electronic = clamp(max(g("electronic"), g("dance"), g("electro"), g("House"), g("electronica")) * 1.6, 0, 1)
            v.topTags = f.tags.sorted { $0.value > $1.value }.prefix(5)
                .filter { $0.value > 0.08 }.map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }
        }

        // Softmax
        let temp = 0.55
        let mx = s.values.max() ?? 0
        var exps: [MusicStyle: Double] = [:]
        var total = 0.0
        for (k, x) in s { let e = exp((x - mx) / temp); exps[k] = e; total += e }
        var best = MusicStyle.pop, bestP = 0.0
        for (k, e) in exps {
            let p = e / total
            v.scores[k.rawValue] = p
            if p > bestP { bestP = p; best = k }
        }
        v.style = best
        v.styleConfidence = bestP

        var d: [String] = []
        if f.fourOnFloor > 0.5 { d.append("four-on-the-floor") }
        if f.backbeat > 0.5 { d.append("backbeat") }
        if f.syncopation > 0.55 { d.append("syncopated") }
        if !f.key.isEmpty && f.tonalClarity > 0.45 { d.append(f.key) }
        let named: [(SoundEvidence, String)] = [(.vocals, "vocals"), (.rap, "rap"), (.electricGuitar, "electric guitar"),
                                                (.acoustic, "acoustic"), (.piano, "piano"), (.strings, "strings"),
                                                (.brass, "brass/winds"), (.synth, "synths"), (.latinPercussion, "percussion")]
        for (e, n) in named where ev(e) > 0.35 { d.append(n) }
        v.descriptors = d
        return v
    }
}
