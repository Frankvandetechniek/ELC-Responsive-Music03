import Foundation

/// A self-running looping "mood" show driven by an internal clock instead of audio.
public struct MoodShow: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var subtitle: String
    /// 1 (very slow) ... 5 (very fast)
    public var speed: Int
    public var bpm: Double
    public var energy: Double
    public var palettes: [Palette]
    public var pool: LookPool
    public var allowsStrobe: Bool
    public var movementScale: Double

    public static let all: [MoodShow] = [breathe, aurora, lounge, brandPulse, club, partyPeak]

    public static let breathe = MoodShow(
        id: "breathe", name: "Breathe", subtitle: "Very slow brand-colour fades, static beams up",
        speed: 1, bpm: 60, energy: 0.2,
        palettes: [.brand, .brandPurple, .brandMagentaPurple],
        pool: LookPool(
            l7Color: [.split, .gradient, .halves, .uniformA, .uniformB],
            l7Intensity: [.breathe, .wave],
            l7Move: [.up, .fan, .vee],
            hybridColor: [.sides, .uniformA, .uniformB, .rows],
            hybridBeam: [.wash],
            hybridIntensity: [.breathe, .wave],
            hybridMove: [.vUp, .fan],
            cycleBeats: [32],
            chaseRates: [0.25],
            l7Zoom: 0.8...1.0, hybridZoom: 0.7...1.0,
            floor: 0.25, moveSmoothing: 2.5, colorFade: 3.0, changeEveryBars: 16),
        allowsStrobe: false, movementScale: 0.4)

    public static let aurora = MoodShow(
        id: "aurora", name: "Aurora", subtitle: "Slow rolling waves of green, purple and blue",
        speed: 2, bpm: 72, energy: 0.3,
        palettes: [.brandPurple, .toxic, .ocean, .brand],
        pool: LookPool(
            l7Color: [.roll, .gradient],
            l7Intensity: [.wave, .breathe],
            l7Move: [.tiltWave, .fanBreath],
            hybridColor: [.rows, .sides],
            hybridBeam: [.goboSpin, .wash],
            hybridIntensity: [.wave, .full],
            hybridMove: [.tiltWave, .sweep],
            cycleBeats: [16, 32],
            chaseRates: [0.25],
            l7Zoom: 0.6...0.9, hybridZoom: 0.5...0.8,
            floor: 0.3, moveSmoothing: 1.5, colorFade: 2.0, changeEveryBars: 16),
        allowsStrobe: false, movementScale: 0.7)

    public static let lounge = MoodShow(
        id: "lounge", name: "Lounge", subtitle: "Warm and magenta, slow gobo sweeps",
        speed: 2, bpm: 90, energy: 0.35,
        palettes: [.sunset, .brandMagentaWhite, .warm, .brand],
        pool: LookPool(
            l7Color: [.split, .halves, .gradient],
            l7Intensity: [.breathe, .wave, .full],
            l7Move: [.fan, .panSway, .fanBreath],
            hybridColor: [.uniformA, .sides],
            hybridBeam: [.goboSpin, .goboPrism],
            hybridIntensity: [.full, .breathe],
            hybridMove: [.sweep, .figure8, .fan],
            cycleBeats: [16],
            chaseRates: [0.5],
            l7Zoom: 0.5...0.8, hybridZoom: 0.3...0.6,
            floor: 0.35, moveSmoothing: 1.0, colorFade: 1.2, changeEveryBars: 8),
        allowsStrobe: false, movementScale: 0.8)

    public static let brandPulse = MoodShow(
        id: "brandPulse", name: "Brand Pulse", subtitle: "Green / magenta chases at a relaxed groove",
        speed: 3, bpm: 110, energy: 0.55,
        palettes: Palette.brandPalettes,
        pool: LookPool(
            l7Color: [.split, .swapOnBeat, .halves, .centerOut],
            l7Intensity: [.pulse, .chase, .oddEven, .centerOut],
            l7Move: [.fan, .tiltWave, .cross, .vee],
            hybridColor: [.sides, .swapOnBar, .rows],
            hybridBeam: [.prism, .beam, .goboPrism],
            hybridIntensity: [.full, .pulse, .chase],
            hybridMove: [.circle, .cross, .tiltWave],
            cycleBeats: [8],
            chaseRates: [1],
            l7Zoom: 0.3...0.6, hybridZoom: 0.1...0.3,
            floor: 0.2, moveSmoothing: 0.4, colorFade: 0.15, changeEveryBars: 8),
        allowsStrobe: false, movementScale: 1.0)

    public static let club = MoodShow(
        id: "club", name: "Club", subtitle: "Driving 124 BPM looks, circles and prisms",
        speed: 4, bpm: 124, energy: 0.72,
        palettes: Palette.brandPalettes + [.ocean, .toxic],
        pool: LookPool.high,
        allowsStrobe: false, movementScale: 1.0)

    public static let partyPeak = MoodShow(
        id: "partyPeak", name: "Party Peak", subtitle: "Fast 138 BPM chases, ballyhoos and short strobe hits",
        speed: 5, bpm: 138, energy: 0.92,
        palettes: Palette.brandPalettes + Palette.extraPalettes,
        pool: LookPool.peak,
        allowsStrobe: true, movementScale: 1.1)
}
