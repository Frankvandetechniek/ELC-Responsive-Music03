import Foundation

/// Musical "section" the engine reacts to.
public enum MusicSection: String, Codable, CaseIterable, Sendable {
    case silence = "Silence"
    case ambient = "Ambient"
    case breakdown = "Breakdown"
    case build = "Build-up"
    case drop = "Drop"
    case groove = "Groove"
    case peak = "Peak"

    public var isHigh: Bool { self == .drop || self == .peak }
}

public enum MusicSource: String, Codable, Sendable {
    case live = "Live input"
    case track = "Setlist track"
    case clock = "Internal clock"
    case none = "None"
}

/// Snapshot of everything the show engine needs to know about the music.
public struct MusicState: Sendable {
    public var source: MusicSource = .none
    /// Monotonic time (seconds) at which `beatPosition` was valid.
    public var timestamp: Double = 0
    public var bpm: Double = 120
    /// Continuous beat counter (integer part = beat number, fraction = phase).
    public var beatPosition: Double = 0
    /// Which beat index (mod 4) is a downbeat ("the one").
    public var downbeatOffset: Int = 0
    public var energy: Double = 0          // 0...1 overall intensity of the music
    public var bass: Double = 0            // 0...1 normalised instantaneous band levels
    public var lowMid: Double = 0
    public var mid: Double = 0
    public var high: Double = 0
    public var kickCount: Int = 0          // increments on every detected kick
    public var snareCount: Int = 0
    public var hatCount: Int = 0
    public var section: MusicSection = .silence
    public var sectionStartBeat: Double = 0
    /// Only known for analysed setlist tracks: beats until the next section change and its kind.
    public var beatsToNextSection: Double? = nil
    public var nextSection: MusicSection? = nil
    public var tempoConfidence: Double = 0
    public var isSilent: Bool = true
    public var trackProgress: Double? = nil
    /// Detected style and mood.
    public var vibe = Vibe()
    /// Learned snare/clap pattern on a 16th grid (0...1 per slot) and how clear it is (0...1).
    public var snarePattern: [Double] = []
    public var snareClarity: Double = 0

    public init() {}

    /// Extrapolates the beat position to `time` (the analyser runs at audio buffer rate,
    /// the DMX engine runs at 44 Hz).
    public func beat(at time: Double) -> Double {
        guard !isSilent || source == .clock else { return beatPosition }
        let dt = clamp(time - timestamp, 0, 0.5)
        return beatPosition + dt * bpm / 60
    }

    /// Bar-relative position: 0..<4 within the current bar.
    public func beatInBar(_ beat: Double) -> Double {
        fmodPositive(beat - Double(downbeatOffset), 4)
    }
}
