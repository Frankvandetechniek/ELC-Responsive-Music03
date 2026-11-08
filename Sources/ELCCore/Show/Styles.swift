import Foundation

public enum Accent: String, Codable, Sendable {
    case none, downbeat, backbeat, everyBeat
}

public enum StrobeUse: String, Codable, Sendable {
    case never       // no strobe at all
    case dropsOnly   // only on a drop impact / the last beats of a known build-up
    case peaks       // drops plus a short hit at the end of an 8-bar phrase at peak energy
}

/// How a lighting designer would light a style: tempo of changes, smoothness, what effects to use.
public struct LightingPersonality: Sendable {
    public var style: MusicStyle
    /// Cue pools for energy level 0 (low), 1 (mid), 2 (high)
    public var levels: [LookPool]
    /// Bars between cue changes (phrase length).
    public var phraseBars: Int
    /// Cue crossfade length in beats.
    public var fadeBeats: Double
    /// Intensity slew limits: time to go 0 → 1 and 1 → 0 (seconds).
    public var attack: Double
    public var release: Double
    /// Movement: natural frequency of the position spring (Hz) and max speed (deg/s).
    public var springHz: Double
    public var maxSpeed: Double
    public var movementSize: Double
    public var accent: Accent
    public var accentAmount: Double
    /// Lights move/chase at half the music tempo (DnB, trap, fast rock).
    public var halfTime: Bool
    public var strobe: StrobeUse
    /// Flash the rig on a drop.
    public var dropImpact: Bool
    public var colorFadeBeats: Double

    /// Electronic dance music: real drops (riser build-up, pre-drop gap, strobe, impact).
    public var dropMusic: Bool { [.edm, .house, .drumAndBass].contains(style) }
    /// Build-ups and big-section hits at all (not for ballads / ambient).
    public var buildEffects: Bool { style != .ballad && style != .ambient }

    public static func `for`(_ style: MusicStyle) -> LightingPersonality {
        switch style {
        case .ambient: return ambient
        case .ballad: return ballad
        case .pop: return pop
        case .rock: return rock
        case .hipHop: return hipHop
        case .house: return house
        case .edm: return edm
        case .drumAndBass: return drumAndBass
        case .latin: return latin
        }
    }

    // MARK: Pools shared by several styles

    static let calmPool = LookPool(
        l7Color: [.uniformA, .split, .gradient, .halves, .centerOut],
        l7Intensity: [.steady, .breathe, .wave],
        l7Move: [.up, .fan, .vee, .fanBreath],
        hybridColor: [.uniformA, .uniformB, .sides, .rows],
        hybridBeam: [.wash, .softGobo],
        hybridIntensity: [.steady, .breathe],
        hybridMove: [.vUp, .fan, .tiltWave],
        cycleBeats: [32, 64], chaseRates: [0.25],
        l7Zoom: 0.65...1.0, hybridZoom: 0.55...0.9, level: 0.7, depth: 0.25, pixels: [.solid, .split, .gradient, .lineGradient])

    static let grooveBase = LookPool(
        l7Color: [.split, .halves, .gradient, .roll, .centerOut, .alternateBar],
        l7Intensity: [.steady, .wave, .chase, .alternate, .barPulse],
        l7Move: [.fan, .tiltWave, .panSway, .vee, .cross, .circle],
        hybridColor: [.sides, .rows, .uniformA, .uniformB],
        hybridBeam: [.goboSpin, .prism, .beam, .softGobo],
        hybridIntensity: [.steady, .wave, .alternate],
        hybridMove: [.circle, .figure8, .tiltWave, .sweep, .cross, .fan],
        cycleBeats: [16, 32], chaseRates: [0.5, 1],
        l7Zoom: 0.35...0.7, hybridZoom: 0.15...0.45, level: 0.85, depth: 0.35,
        pixels: [.solid, .split, .gradient, .lineGradient, .wave])

    static let highBase = LookPool(
        l7Color: [.split, .alternateBar, .halves, .centerOut, .gradient],
        l7Intensity: [.pulse, .chase, .bounce, .alternate, .centerOut, .barPulse],
        l7Move: [.tiltWave, .panSway, .circle, .cross, .fan],
        hybridColor: [.sides, .rows, .accentCenter, .uniformA],
        hybridBeam: [.beam, .prism, .goboPrism, .linearPrism],
        hybridIntensity: [.steady, .pulse, .chase, .alternate],
        hybridMove: [.circle, .figure8, .ballyhoo, .sweep, .cross],
        cycleBeats: [8, 16], chaseRates: [1],
        l7Zoom: 0.1...0.4, hybridZoom: 0.0...0.25, level: 1.0, depth: 0.45,
        pixels: [.solid, .split, .wave, .travel, .centerPulse])

    static func tweak(_ p: LookPool, _ f: (inout LookPool) -> Void) -> LookPool { var c = p; f(&c); return c }

    // MARK: Personalities

    public static let ambient = LightingPersonality(
        style: .ambient,
        levels: [calmPool,
                 tweak(calmPool) { $0.level = 0.8; $0.cycleBeats = [32] },
                 tweak(calmPool) { $0.level = 0.9; $0.l7Intensity = [.wave, .steady]; $0.cycleBeats = [16, 32] }],
        phraseBars: 16, fadeBeats: 8, attack: 1.2, release: 1.8, springHz: 0.35, maxSpeed: 25,
        movementSize: 0.6, accent: .none, accentAmount: 0, halfTime: true, strobe: .never,
        dropImpact: false, colorFadeBeats: 4)

    public static let ballad = LightingPersonality(
        style: .ballad,
        levels: [tweak(calmPool) { $0.l7Move = [.up, .fan, .vee] },
                 tweak(calmPool) { $0.level = 0.82; $0.hybridBeam = [.softGobo, .wash, .goboSpin]; $0.cycleBeats = [32] },
                 tweak(grooveBase) { $0.l7Intensity = [.steady, .wave]; $0.hybridIntensity = [.steady]
                     $0.cycleBeats = [32]; $0.depth = 0.2; $0.hybridBeam = [.softGobo, .goboSpin, .beam] }],
        phraseBars: 8, fadeBeats: 4, attack: 0.6, release: 1.2, springHz: 0.5, maxSpeed: 35,
        movementSize: 0.6, accent: .none, accentAmount: 0, halfTime: true, strobe: .never,
        dropImpact: false, colorFadeBeats: 4)

    public static let pop = LightingPersonality(
        style: .pop,
        levels: [calmPool,
                 tweak(grooveBase) { $0.l7Intensity += [.snareChase, .snareAlternate, .snareHit] },
                 tweak(highBase) { $0.l7Intensity += [.snareChase, .snareHit, .snareAlternate]
                     $0.hybridIntensity += [.snareHit, .snareAlternate] }],
        phraseBars: 8, fadeBeats: 2, attack: 0.07, release: 0.35, springHz: 1.0, maxSpeed: 90,
        movementSize: 0.9, accent: .downbeat, accentAmount: 0.12, halfTime: false, strobe: .dropsOnly,
        dropImpact: true, colorFadeBeats: 1)

    public static let rock = LightingPersonality(
        style: .rock,
        levels: [tweak(calmPool) { $0.l7Color = [.uniformA, .split, .halves] },
                 tweak(grooveBase) { $0.l7Intensity = [.steady, .snareChase, .snareHit, .alternate]; $0.hybridBeam = [.beam, .goboSpin, .prism] },
                 tweak(highBase) { $0.l7Intensity = [.snareHit, .snareChase, .snareAlternate, .alternate, .pulse]
                     $0.hybridIntensity += [.snareHit]; $0.hybridMove = [.cross, .sweep, .ballyhoo, .fan]
                     $0.hybridBeam = [.beam, .goboPrism, .prism] }],
        phraseBars: 8, fadeBeats: 1, attack: 0.06, release: 0.3, springHz: 1.4, maxSpeed: 140,
        movementSize: 1.0, accent: .backbeat, accentAmount: 0.15, halfTime: false, strobe: .dropsOnly,
        dropImpact: true, colorFadeBeats: 0.5)

    public static let hipHop = LightingPersonality(
        style: .hipHop,
        levels: [calmPool,
                 tweak(grooveBase) { $0.l7Intensity = [.steady, .snareHit, .snareChase, .wave]; $0.chaseRates = [0.5]; $0.cycleBeats = [16, 32] },
                 tweak(highBase) { $0.l7Intensity = [.snareHit, .snareChase, .snareAlternate, .halfPulse]; $0.chaseRates = [0.5]
                     $0.hybridMove = [.sweep, .cross, .figure8, .tiltWave] }],
        phraseBars: 8, fadeBeats: 2, attack: 0.08, release: 0.45, springHz: 0.8, maxSpeed: 70,
        movementSize: 0.8, accent: .backbeat, accentAmount: 0.12, halfTime: true, strobe: .dropsOnly,
        dropImpact: true, colorFadeBeats: 1)

    public static let house = LightingPersonality(
        style: .house,
        levels: [tweak(calmPool) { $0.l7Intensity = [.wave, .breathe, .steady] },
                 tweak(grooveBase) { $0.l7Intensity = [.wave, .steady, .chase, .barPulse, .snareAlternate]; $0.cycleBeats = [16, 32] },
                 tweak(highBase) { $0.l7Intensity = [.pulse, .chase, .centerOut, .wave]; $0.depth = 0.35; $0.cycleBeats = [16] }],
        phraseBars: 16, fadeBeats: 4, attack: 0.08, release: 0.35, springHz: 0.9, maxSpeed: 100,
        movementSize: 1.0, accent: .everyBeat, accentAmount: 0.12, halfTime: false, strobe: .dropsOnly,
        dropImpact: true, colorFadeBeats: 2)

    /// Festival EDM: big, fast and punchy on drops — beams flying, pulses on every beat, colour swaps on bars.
    public static let edm = LightingPersonality(
        style: .edm,
        levels: [calmPool,
                 tweak(grooveBase) { $0.l7Intensity = [.chase, .pulse, .centerOut, .alternate, .snareChase]; $0.chaseRates = [1]
                     $0.cycleBeats = [8, 16] },
                 tweak(highBase) { $0.depth = 0.55; $0.cycleBeats = [4, 8]; $0.chaseRates = [1]
                     $0.l7Intensity = [.pulse, .chase, .bounce, .centerOut, .snareHit, .snareAlternate]
                     $0.l7Color = [.alternateBar, .split, .halves, .centerOut]
                     $0.hybridIntensity = [.pulse, .steady, .chase, .snareHit]
                     $0.hybridMove = [.ballyhoo, .circle, .figure8, .sweep, .cross, .fan]
                     $0.hybridBeam = [.beam, .prism, .linearPrism, .goboPrism]
                     $0.l7Pixels = [.travel, .centerPulse, .wave, .split] }],
        phraseBars: 8, fadeBeats: 1, attack: 0.04, release: 0.25, springHz: 1.6, maxSpeed: 170,
        movementSize: 1.15, accent: .downbeat, accentAmount: 0.25, halfTime: false, strobe: .peaks,
        dropImpact: true, colorFadeBeats: 0.25)

    public static let drumAndBass = LightingPersonality(
        style: .drumAndBass,
        levels: [calmPool,
                 tweak(grooveBase) { $0.chaseRates = [0.5] },
                 tweak(highBase) { $0.chaseRates = [0.5, 1]; $0.l7Intensity = [.halfPulse, .chase, .snareChase, .snareHit, .alternate] }],
        phraseBars: 8, fadeBeats: 1, attack: 0.06, release: 0.3, springHz: 1.2, maxSpeed: 120,
        movementSize: 1.0, accent: .backbeat, accentAmount: 0.1, halfTime: true, strobe: .dropsOnly,
        dropImpact: true, colorFadeBeats: 0.5)

    public static let latin = LightingPersonality(
        style: .latin,
        levels: [tweak(calmPool) { $0.l7Color = [.gradient, .roll, .split] },
                 tweak(grooveBase) { $0.l7Move = [.panSway, .tiltWave, .circle]; $0.hybridMove = [.sweep, .figure8, .circle]
                     $0.l7Intensity += [.snareChase]
                     $0.l7Color = [.roll, .gradient, .split, .alternateBar] },
                 tweak(highBase) { $0.l7Move = [.panSway, .circle, .tiltWave]; $0.l7Intensity = [.wave, .chase, .alternate, .pulse] }],
        phraseBars: 8, fadeBeats: 2, attack: 0.1, release: 0.4, springHz: 0.9, maxSpeed: 80,
        movementSize: 1.0, accent: .everyBeat, accentAmount: 0.08, halfTime: false, strobe: .dropsOnly,
        dropImpact: true, colorFadeBeats: 1)
}

// MARK: - Mood-matched palettes

extension Palette {
    public static let midnight = Palette(name: "Midnight", a: .deepBlue, b: .brandPurple, accent: .lightBlue, isBrand: false)
    public static let rose = Palette(name: "Rose", a: .amber, b: .pink, accent: .white, isBrand: false)
    public static let candy = Palette(name: "Candy", a: .pink, b: .cyan, accent: .white, isBrand: false)
    public static let darkRed = Palette(name: "Dark Red", a: .red, b: .brandPurple, accent: .amber, isBrand: false)

    /// Palettes fitting a mood, respecting the colour policy. Brand palettes are always favoured;
    /// which brand palette depends on the mood too.
    public static func forMood(valence: Double, arousal: Double, policy: ColorPolicy) -> [Palette] {
        let brand: [Palette]
        switch (arousal >= 0.5, valence >= 0.5) {
        case (true, true): brand = [.brand, .brand, .brandGreenWhite, .brandPurple]
        case (true, false): brand = [.brandMagentaPurple, .brandPurple, .brand]
        case (false, true): brand = [.brandMagentaWhite, .brand, .brandPurple]
        case (false, false): brand = [.brandPurple, .brandMagentaPurple]
        }
        let extra: [Palette]
        switch (arousal >= 0.5, valence >= 0.5) {
        case (true, true): extra = [.sunset, .candy, .toxic]
        case (true, false): extra = [.darkRed, .fire, .toxic]
        case (false, true): extra = [.rose, .warm, .sunset]
        case (false, false): extra = [.midnight, .ocean, .ice]
        }
        switch policy {
        case .brandOnly: return brand
        case .brandMostly: return brand + brand + brand + extra
        case .anything: return brand + extra + extra
        }
    }
}
