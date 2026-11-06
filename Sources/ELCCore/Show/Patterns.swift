import Foundation

// MARK: - Building blocks of a look

public enum L7ColorPattern: String, CaseIterable, Codable, Sendable {
    case uniformA, uniformB, split, halves, gradient, roll, centerOut, swapOnBeat
}

public enum IntensityPattern: String, CaseIterable, Codable, Sendable {
    case full, breathe, pulse, pulseHalf, chase, chaseFast, bounce, centerOut, oddEven, sparkle, wave, kick
}

public enum L7Move: String, CaseIterable, Codable, Sendable {
    case up, forward, fan, vee, cross, tiltWave, panSway, fanBreath, circle
}

public enum HybridColorPattern: String, CaseIterable, Codable, Sendable {
    case uniformA, uniformB, sides, rows, swapOnBar, accent
}

public enum HybridBeam: String, CaseIterable, Codable, Sendable {
    case wash, beam, prism, goboSpin, goboPrism, linearPrism, shake
}

public enum HybridMove: String, CaseIterable, Codable, Sendable {
    case vUp, fan, cross, forward, audience, circle, figure8, tiltWave, sweep, ballyhoo
}

/// The complete description of what the rig is doing right now.
public struct Look: Equatable, Sendable {
    public var palette: Palette = .brand
    public var l7Color: L7ColorPattern = .split
    public var l7Intensity: IntensityPattern = .full
    public var l7Move: L7Move = .fan
    public var hybridColor: HybridColorPattern = .sides
    public var hybridBeam: HybridBeam = .beam
    public var hybridIntensity: IntensityPattern = .full
    public var hybridMove: HybridMove = .vUp
    public var gobo: Int = 3
    public var moveCycleBeats: Double = 8
    public var chaseRate: Double = 1       // steps per beat
    public var l7Zoom: Double = 0.5
    public var hybridZoom: Double = 0.2
    public var floor: Double = 0.3         // minimum intensity of patterned fixtures
    public var moveSmoothing: Double = 0.2 // seconds
    public var colorFade: Double = 0.1     // seconds

    public init() {}

    public var summary: String {
        "L7: \(l7Color.rawValue) · \(l7Intensity.rawValue) · \(l7Move.rawValue)   Hybrid: \(hybridBeam.rawValue) · \(hybridIntensity.rawValue) · \(hybridMove.rawValue)"
    }
}

/// Which building blocks are allowed for a given energy tier or mood show.
public struct LookPool: Sendable {
    public var l7Color: [L7ColorPattern]
    public var l7Intensity: [IntensityPattern]
    public var l7Move: [L7Move]
    public var hybridColor: [HybridColorPattern]
    public var hybridBeam: [HybridBeam]
    public var hybridIntensity: [IntensityPattern]
    public var hybridMove: [HybridMove]
    public var cycleBeats: [Double]
    public var chaseRates: [Double]
    public var l7Zoom: ClosedRange<Double>
    public var hybridZoom: ClosedRange<Double>
    public var floor: Double
    public var moveSmoothing: Double
    public var colorFade: Double
    public var changeEveryBars: Int
    public var gobos: [Int] = [2, 3, 5, 6, 7]

    public init(l7Color: [L7ColorPattern], l7Intensity: [IntensityPattern], l7Move: [L7Move],
                hybridColor: [HybridColorPattern], hybridBeam: [HybridBeam], hybridIntensity: [IntensityPattern],
                hybridMove: [HybridMove], cycleBeats: [Double], chaseRates: [Double],
                l7Zoom: ClosedRange<Double>, hybridZoom: ClosedRange<Double>, floor: Double,
                moveSmoothing: Double, colorFade: Double, changeEveryBars: Int) {
        self.l7Color = l7Color; self.l7Intensity = l7Intensity; self.l7Move = l7Move
        self.hybridColor = hybridColor; self.hybridBeam = hybridBeam; self.hybridIntensity = hybridIntensity
        self.hybridMove = hybridMove; self.cycleBeats = cycleBeats; self.chaseRates = chaseRates
        self.l7Zoom = l7Zoom; self.hybridZoom = hybridZoom; self.floor = floor
        self.moveSmoothing = moveSmoothing; self.colorFade = colorFade; self.changeEveryBars = changeEveryBars
    }

    // Energy tiers used when following music.
    public static let calm = LookPool(
        l7Color: [.uniformA, .split, .gradient, .halves, .centerOut],
        l7Intensity: [.breathe, .wave, .full],
        l7Move: [.up, .fan, .tiltWave, .fanBreath, .vee],
        hybridColor: [.uniformA, .uniformB, .sides, .rows],
        hybridBeam: [.wash, .goboSpin, .wash],
        hybridIntensity: [.full, .breathe, .wave],
        hybridMove: [.vUp, .fan, .tiltWave, .sweep],
        cycleBeats: [16, 32],
        chaseRates: [0.25, 0.5],
        l7Zoom: 0.6...1.0, hybridZoom: 0.5...0.9,
        floor: 0.35, moveSmoothing: 0.8, colorFade: 1.2, changeEveryBars: 8)

    public static let groove = LookPool(
        l7Color: [.split, .halves, .gradient, .roll, .centerOut, .uniformA],
        l7Intensity: [.pulse, .chase, .oddEven, .wave, .kick, .centerOut],
        l7Move: [.fan, .tiltWave, .panSway, .vee, .cross, .circle],
        hybridColor: [.sides, .rows, .uniformA, .uniformB, .swapOnBar],
        hybridBeam: [.goboSpin, .prism, .beam, .goboPrism, .linearPrism],
        hybridIntensity: [.full, .pulse, .chase, .oddEven],
        hybridMove: [.circle, .figure8, .tiltWave, .sweep, .cross, .fan],
        cycleBeats: [8, 16],
        chaseRates: [0.5, 1],
        l7Zoom: 0.3...0.7, hybridZoom: 0.1...0.5,
        floor: 0.2, moveSmoothing: 0.35, colorFade: 0.25, changeEveryBars: 8)

    public static let high = LookPool(
        l7Color: [.split, .roll, .swapOnBeat, .halves, .centerOut, .gradient],
        l7Intensity: [.pulse, .chase, .chaseFast, .bounce, .oddEven, .kick, .sparkle],
        l7Move: [.tiltWave, .panSway, .circle, .cross, .fan, .vee],
        hybridColor: [.sides, .rows, .swapOnBar, .accent, .uniformA],
        hybridBeam: [.beam, .prism, .goboPrism, .linearPrism, .shake],
        hybridIntensity: [.pulse, .chase, .oddEven, .full, .sparkle],
        hybridMove: [.circle, .figure8, .ballyhoo, .sweep, .cross, .tiltWave],
        cycleBeats: [4, 8],
        chaseRates: [1, 2],
        l7Zoom: 0.05...0.4, hybridZoom: 0.0...0.25,
        floor: 0.1, moveSmoothing: 0.18, colorFade: 0.08, changeEveryBars: 4)

    public static let peak = LookPool(
        l7Color: [.swapOnBeat, .split, .roll, .centerOut],
        l7Intensity: [.pulse, .chaseFast, .bounce, .sparkle, .kick, .oddEven],
        l7Move: [.circle, .panSway, .tiltWave, .cross],
        hybridColor: [.swapOnBar, .sides, .accent, .rows],
        hybridBeam: [.beam, .prism, .linearPrism, .shake],
        hybridIntensity: [.pulse, .chase, .sparkle, .oddEven],
        hybridMove: [.ballyhoo, .circle, .figure8, .sweep],
        cycleBeats: [2, 4],
        chaseRates: [2, 4],
        l7Zoom: 0.0...0.25, hybridZoom: 0.0...0.15,
        floor: 0.05, moveSmoothing: 0.12, colorFade: 0.05, changeEveryBars: 4)

    public static func tier(_ t: Int) -> LookPool {
        switch t {
        case 0: return .calm
        case 1: return .groove
        case 2: return .high
        default: return .peak
        }
    }
}

// MARK: - Pattern evaluation

enum PatternMath {
    /// Intensity 0...1 for a fixture at `index` (in chase order) of `count`.
    static func intensity(_ p: IntensityPattern, beat b: Double, index i: Int, count n: Int,
                          rate: Double, cycle: Double, kickEnv: Double, x: Double) -> Double {
        let nD = Double(max(n, 1))
        switch p {
        case .full:
            return 1
        case .breathe:
            let ph = 2 * Double.pi * (b / max(cycle, 1) + Double(i) * 0.08)
            return 0.55 - 0.45 * cos(ph)
        case .pulse:
            return exp(-fmodPositive(b, 1) * 3.5)
        case .pulseHalf:
            return exp(-fmodPositive(b * 2, 1) * 3.5)
        case .chase, .chaseFast:
            let r = p == .chaseFast ? rate * 2 : rate
            let d = fmodPositive(b * r - Double(i), nD)
            return max(0, 1 - d * 0.9)
        case .bounce:
            let period = 2 * (nD - 1)
            let posRaw = fmodPositive(b * rate * 2, max(period, 1))
            let pos = posRaw <= nD - 1 ? posRaw : period - posRaw
            return max(0, 1 - abs(pos - Double(i)) * 1.1)
        case .centerOut:
            let wave = fmodPositive(b * rate * 0.5, 1)
            return max(0, 1 - abs(abs(x) - wave) * 2.8)
        case .oddEven:
            let step = Int(floor(b * rate))
            let on = (step + i) % 2 == 0
            return on ? exp(-fmodPositive(b * rate, 1) * 1.5) : 0
        case .sparkle:
            let step = Int(floor(b * rate * 2))
            let hit = hashNoise(step * 31 + i, seed: 7) > 0.55
            return hit ? exp(-fmodPositive(b * rate * 2, 1) * 4) : 0
        case .wave:
            return 0.5 + 0.5 * sin(2 * .pi * (b / max(cycle, 1) - Double(i) / nD))
        case .kick:
            return kickEnv
        }
    }

    static func l7Color(_ p: L7ColorPattern, palette: Palette, beat b: Double, index i: Int, x: Double) -> RGB {
        switch p {
        case .uniformA: return palette.a
        case .uniformB: return palette.b
        case .split: return i % 2 == 0 ? palette.a : palette.b
        case .halves: return x < 0 ? palette.a : palette.b
        case .gradient: return palette.a.mix(palette.b, (x + 1) / 2)
        case .roll:
            let t = 0.5 + 0.5 * sin(2 * .pi * (b / 8 - Double(i) / 6))
            return palette.a.mix(palette.b, t)
        case .centerOut: return abs(x) < 0.5 ? palette.a : palette.b
        case .swapOnBeat:
            let flip = (Int(floor(b)) + i) % 2 == 0
            return flip ? palette.a : palette.b
        }
    }

    static func hybridColor(_ p: HybridColorPattern, palette: Palette, bar: Int, side: Int, row: Int) -> RGB {
        switch p {
        case .uniformA: return palette.a
        case .uniformB: return palette.b
        case .sides: return side < 0 ? palette.a : palette.b
        case .rows: return row % 2 == 0 ? palette.a : palette.b
        case .swapOnBar: return (bar + (side < 0 ? 0 : 1)) % 2 == 0 ? palette.a : palette.b
        case .accent: return row == 1 ? palette.accent : palette.a
        }
    }

    /// L7 aim (pan, tilt). x in -1...1 (left to right).
    static func l7Aim(_ m: L7Move, beat b: Double, index i: Int, x: Double, cycle: Double, amount: Double) -> (Double, Double) {
        let w = 2 * Double.pi * b / max(cycle, 0.5)
        switch m {
        case .up: return (0, 4)
        case .forward: return (0, 42)
        case .fan: return (x * 40 * amount, 28)
        case .vee: return (0, i % 2 == 0 ? 12 : 48)
        case .cross: return (-x * 35 * amount, 32)
        case .tiltWave: return (x * 12, 30 + 24 * amount * sin(w - Double(i) * 0.7))
        case .panSway:
            let s = sin(w)
            return ((x < 0 ? -1 : 1) * 30 * amount * s, 34)
        case .fanBreath: return (x * 42 * amount * (0.5 + 0.5 * sin(w)), 22 + 10 * sin(w))
        case .circle:
            let ph = w + Double(i) * .pi / 3
            return (22 * amount * sin(ph), 34 + 16 * amount * cos(ph))
        }
    }

    /// Hybrid aim (pan, tilt). side -1 (left) / +1 (right), row 0 (upstage pair) ... 2 (downstage pair).
    static func hybridAim(_ m: HybridMove, beat b: Double, number n: Int, side: Int, row: Int,
                          cycle: Double, amount: Double) -> (Double, Double) {
        let s = Double(side), r = Double(row)
        let w = 2 * Double.pi * b / max(cycle, 0.5)
        switch m {
        case .vUp: return (s * 70, 14 + 8 * r)
        case .fan: return (s * (25 + 18 * r), 30)
        case .cross: return (-s * 55, 30 + 6 * r)
        case .forward: return (s * 8, 38)
        case .audience: return (s * (10 + 8 * r), 62)
        case .circle:
            let ph = w + Double(n) * .pi / 3
            return (s * 25 + 28 * amount * sin(ph), 34 + 16 * amount * cos(ph))
        case .figure8:
            let ph = w + (side < 0 ? 0 : .pi)
            return (s * 20 + 32 * amount * sin(ph), 34 + 14 * amount * sin(2 * ph))
        case .tiltWave:
            return (s * 40, 30 + 26 * amount * sin(w - r * 0.9))
        case .sweep:
            return (s * 45 * amount * sin(w), 38)
        case .ballyhoo:
            let k = Double(n) * 1.7
            let p = 40 * amount * (0.6 * sin(w * 0.5 + k) + 0.4 * sin(w * 1.3 + 2 * k))
            let t = 34 + 20 * amount * (0.6 * sin(w * 0.7 + 3 * k) + 0.4 * cos(w * 1.1 + k))
            return (s * 15 + p, t)
        }
    }
}
