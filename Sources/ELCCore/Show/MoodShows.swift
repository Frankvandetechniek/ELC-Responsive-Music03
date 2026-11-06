import Foundation

/// A self-running looping "mood" show driven by an internal clock instead of audio.
public struct MoodShow: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var subtitle: String
    /// 1 (very slow) ... 5 (fast)
    public var speed: Int
    public var bpm: Double
    public var energy: Double
    /// Energy level 0 (low), 1 (mid), 2 (high) of the cue pool used.
    public var level: Int
    public var palettes: [Palette]
    public var personality: LightingPersonality
    public var allowsStrobe: Bool

    public static let all: [MoodShow] = [breathe, aurora, lounge, brandPulse, club, partyPeak]

    public static let breathe = MoodShow(
        id: "breathe", name: "Breathe", subtitle: "Very slow brand-colour fades, beams up, soft frost",
        speed: 1, bpm: 60, energy: 0.2, level: 0,
        palettes: [.brand, .brandPurple, .brandMagentaPurple],
        personality: .ambient, allowsStrobe: false)

    public static let aurora = MoodShow(
        id: "aurora", name: "Aurora", subtitle: "Slow rolling waves of green, purple and blue",
        speed: 2, bpm: 72, energy: 0.3, level: 1,
        palettes: [.brandPurple, .toxic, .ocean, .midnight, .brand],
        personality: { var p = LightingPersonality.ambient
            p.levels[1].l7Color = [.roll, .gradient]; p.levels[1].l7Intensity = [.wave]
            p.levels[1].l7Move = [.tiltWave, .fanBreath]; p.levels[1].hybridMove = [.tiltWave, .sweep]
            p.levels[1].hybridBeam = [.softGobo, .wash]; p.movementSize = 0.8
            return p }(),
        allowsStrobe: false)

    public static let lounge = MoodShow(
        id: "lounge", name: "Lounge", subtitle: "Warm amber and magenta, slow gobo sweeps",
        speed: 2, bpm: 90, energy: 0.35, level: 1,
        palettes: [.rose, .sunset, .brandMagentaWhite, .warm],
        personality: .ballad, allowsStrobe: false)

    public static let brandPulse = MoodShow(
        id: "brandPulse", name: "Brand Pulse", subtitle: "Green / magenta looks with gentle chases",
        speed: 3, bpm: 110, energy: 0.55, level: 1,
        palettes: Palette.brandPalettes,
        personality: .pop, allowsStrobe: false)

    public static let club = MoodShow(
        id: "club", name: "Club", subtitle: "Hypnotic 124 BPM club looks, prisms and sweeps",
        speed: 4, bpm: 124, energy: 0.72, level: 2,
        palettes: Palette.brandPalettes + [.ocean, .toxic, .midnight],
        personality: .house, allowsStrobe: false)

    public static let partyPeak = MoodShow(
        id: "partyPeak", name: "Party Peak", subtitle: "Big 138 BPM festival looks, short strobe hits",
        speed: 5, bpm: 138, energy: 0.92, level: 2,
        palettes: Palette.brandPalettes + [.sunset, .candy, .fire],
        personality: .edm, allowsStrobe: true)
}
