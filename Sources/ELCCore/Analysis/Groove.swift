import Foundation

/// Learns where the snare (or clap) falls within the bar on a 16th-note grid.
/// Lighting then follows this learned pattern on the beat clock, so snare chases land exactly
/// on the hit (no detection latency) and stray false detections don't cause flicker.
public struct GrooveTracker: Sendable {
    public static let slots = 16
    /// Bar-to-bar memory (live). `nil` = plain average (whole track / section).
    public var decayPerBar: Double?
    private var acc = [Double](repeating: 0, count: GrooveTracker.slots)
    private var weight = 0.0
    private var currentSlot = -1
    private var currentMax = 0.0
    private var lastBar = Int.min

    public init(decayPerBar: Double?) { self.decayPerBar = decayPerBar }

    /// Snare onset strength for a frame: needs both the body (mid band) and the noisy crack (high band),
    /// which separates snares/claps from kicks (low only) and hi-hats (high only).
    public static func snareStrength(_ f: FrameFeatures) -> Double {
        (max(f.flux[2], 0) * max(f.flux[3], 0)).squareRoot()
    }

    public mutating func add(_ f: FrameFeatures, beatPosition b: Double, downbeatOffset: Int) {
        let barPos = fmodPositive(b - Double(downbeatOffset), 4) * 4   // 0..<16 in 16ths
        let bar = Int(floor((b - Double(downbeatOffset)) / 4))
        let nearest = Int(barPos.rounded()) % GrooveTracker.slots
        let dist = abs(barPos - barPos.rounded())
        if bar != lastBar {
            if let d = decayPerBar, lastBar != Int.min {
                for i in 0..<GrooveTracker.slots { acc[i] *= d }
                weight *= d
            }
            lastBar = bar
            weight += 1
        }
        if nearest != currentSlot {
            if currentSlot >= 0 { acc[currentSlot] += currentMax }
            currentSlot = nearest
            currentMax = 0
        }
        if dist < 0.35 { currentMax = max(currentMax, GrooveTracker.snareStrength(f)) }
    }

    /// The learned pattern (0...1 per 16th, normalised to the strongest slot) and how clear it is.
    public var pattern: (slots: [Double], clarity: Double) {
        guard weight > 1.5, let mx = acc.max(), mx > 1e-9 else { return ([Double](repeating: 0, count: GrooveTracker.slots), 0) }
        let norm = acc.map { $0 / mx }
        let sorted = norm.sorted(by: >)
        let peak = sorted.prefix(2).reduce(0, +) / 2
        let rest = sorted.dropFirst(4).reduce(0, +) / Double(max(1, sorted.count - 4))
        let clarity = clamp((peak - rest) / max(peak, 1e-9), 0, 1)
        return (norm, clarity)
    }
}

/// Snare steps used by the lighting patterns: the 16th positions (0..<16) that carry the snare.
public struct SnareSteps: Equatable, Sendable {
    public var slots: [Int]
    public var learned: Bool

    /// Beats 2 and 4 (the backbeat) — the fallback when no clear pattern was learned.
    public static let backbeat = SnareSteps(slots: [4, 12], learned: false)

    public init(slots: [Int], learned: Bool) {
        self.slots = slots.sorted()
        self.learned = learned
    }

    /// Picks up to 4 strong slots per bar (keeps chases musical, never frantic).
    public static func from(pattern: [Double], clarity: Double) -> SnareSteps {
        guard pattern.count == GrooveTracker.slots, clarity > 0.35 else { return .backbeat }
        let strong = pattern.indices.filter { pattern[$0] >= 0.55 }
            .sorted { pattern[$0] > pattern[$1] }
            .prefix(4)
        // At least 2 hits a bar and not on every 16th: otherwise it's not a snare groove.
        guard strong.count >= 2 else { return .backbeat }
        // Avoid adjacent 16ths (flams / ghost notes) — keep the stronger one.
        var chosen: [Int] = []
        for s in strong where !chosen.contains(where: { min(abs($0 - s), 16 - abs($0 - s)) <= 1 }) { chosen.append(s) }
        return chosen.count >= 2 ? SnareSteps(slots: chosen, learned: true) : .backbeat
    }

    /// Step count and position relative to the bar: returns (total steps since bar 0, 16ths since the last step,
    /// average 16ths between steps).
    public func position(bar: Int, barBeat: Double) -> (step: Int, since: Double, interval: Double) {
        let s16 = barBeat * 4
        let perBar = slots.count
        var inBar = 0
        var last = Double(slots.last! - 16)   // last hit of the previous bar
        for slot in slots where Double(slot) <= s16 { inBar += 1; last = Double(slot) }
        let step = bar * perBar + inBar - 1
        return (step, s16 - last, 16 / Double(perBar))
    }
}
