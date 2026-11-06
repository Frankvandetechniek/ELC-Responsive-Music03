import Foundation

// MARK: - Building blocks of a cue
//
// Design rules (to look like a programmed show, not an audio visualiser):
//  * every pattern is a smooth function of the beat clock — no hard on/off steps
//  * nothing reacts to loudness directly; music only chooses *which* cue runs and when it changes
//  * chases step at most once per beat (normally slower), colours change on bars/phrases with fades,
//    the Hybrid colour wheel / gobos / prisms only change between cues (in black)

public enum L7ColorPattern: String, CaseIterable, Codable, Sendable {
    case uniformA, uniformB, split, halves, gradient, roll, centerOut, alternateBar
}

public enum IntensityPattern: String, CaseIterable, Codable, Sendable {
    case steady, breathe, wave, pulse, halfPulse, barPulse, backbeat, chase, bounce, centerOut, alternate
    /// Follow the song's snare: each snare hit moves the chase one fixture on (hit + fade).
    case snareChase
    /// Every snare hit bumps all fixtures.
    case snareHit
    /// Snare hits alternate between odd and even fixtures.
    case snareAlternate

    public var isSnare: Bool { self == .snareChase || self == .snareHit || self == .snareAlternate }
}

public enum L7Move: String, CaseIterable, Codable, Sendable {
    case up, forward, fan, vee, cross, tiltWave, panSway, fanBreath, circle
}

public enum HybridColorPattern: String, CaseIterable, Codable, Sendable {
    case uniformA, uniformB, sides, rows, accentCenter
}

public enum HybridBeam: String, CaseIterable, Codable, Sendable {
    case wash, softGobo, beam, prism, goboSpin, goboPrism, linearPrism
}

public enum HybridMove: String, CaseIterable, Codable, Sendable {
    case vUp, fan, cross, forward, audience, circle, figure8, tiltWave, sweep, ballyhoo
}

/// One "cue": what the whole rig does until the director changes it.
public struct Look: Equatable, Sendable {
    public var palette: Palette = .brand
    public var l7Color: L7ColorPattern = .split
    public var l7Intensity: IntensityPattern = .steady
    public var l7Move: L7Move = .fan
    public var hybridColor: HybridColorPattern = .sides
    public var hybridBeam: HybridBeam = .beam
    public var hybridIntensity: IntensityPattern = .steady
    public var hybridMove: HybridMove = .vUp
    public var gobo: Int = 3
    public var moveCycleBeats: Double = 16
    public var chaseRate: Double = 0.5       // steps per beat (≤ 1)
    public var l7Zoom: Double = 0.5
    public var hybridZoom: Double = 0.3
    public var level: Double = 0.85          // overall intensity of the cue
    public var depth: Double = 0.3           // how deep the intensity pattern modulates
    public var movementSize: Double = 1
    /// Snare steps captured when the cue started (so a chase never jumps mid-cue).
    public var snare: SnareSteps = .backbeat

    public init() {}

    public var summary: String {
        "L7: \(l7Color.rawValue) · \(l7Intensity.rawValue) · \(l7Move.rawValue)   Hybrid: \(hybridBeam.rawValue) · \(hybridIntensity.rawValue) · \(hybridMove.rawValue)"
    }
}

/// Which building blocks a style allows at one energy level.
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
    public var level: Double
    public var depth: Double
    public var gobos: [Int] = [2, 3, 5, 6, 7]

    public init(l7Color: [L7ColorPattern], l7Intensity: [IntensityPattern], l7Move: [L7Move],
                hybridColor: [HybridColorPattern], hybridBeam: [HybridBeam], hybridIntensity: [IntensityPattern],
                hybridMove: [HybridMove], cycleBeats: [Double], chaseRates: [Double],
                l7Zoom: ClosedRange<Double>, hybridZoom: ClosedRange<Double>, level: Double, depth: Double) {
        self.l7Color = l7Color; self.l7Intensity = l7Intensity; self.l7Move = l7Move
        self.hybridColor = hybridColor; self.hybridBeam = hybridBeam; self.hybridIntensity = hybridIntensity
        self.hybridMove = hybridMove; self.cycleBeats = cycleBeats; self.chaseRates = chaseRates
        self.l7Zoom = l7Zoom; self.hybridZoom = hybridZoom; self.level = level; self.depth = depth
    }
}

// MARK: - Pattern evaluation

enum PatternMath {
    /// Raised-cosine window: 1 at distance 0, 0 at `width` and beyond.
    @inline(__always) static func window(_ d: Double, _ width: Double) -> Double {
        let a = abs(d)
        return a >= width ? 0 : 0.5 + 0.5 * cos(.pi * a / width)
    }

    /// Smooth decay envelope for pulses (0 ... 1 phase). Starts at 1, reaches 0 at the end.
    @inline(__always) static func decay(_ phase: Double) -> Double {
        let p = clamp(phase, 0, 1)
        return (1 - p) * (1 - p)
    }

    /// Intensity 0...1 for a fixture at `index` (in chase order) of `count`.
    /// `beat` is the continuous beat clock, `barBeat` the position within the bar (0..<4), `bar` the bar index.
    static func intensity(_ p: IntensityPattern, beat b: Double, barBeat: Double, bar: Int, index i: Int, count n: Int,
                          rate: Double, cycle: Double, x: Double, snare: SnareSteps = .backbeat) -> Double {
        let nD = Double(max(n, 1))
        switch p {
        case .snareChase:
            let pos = snare.position(bar: bar, barBeat: barBeat)
            let s = pos.step
            // most recent step that landed on this fixture
            let back = ((s - i) % n + n) % n
            let age = Double(back) * pos.interval + pos.since
            return decay(age / (pos.interval * 1.6))
        case .snareHit:
            let pos = snare.position(bar: bar, barBeat: barBeat)
            return decay(pos.since / (pos.interval * 0.9))
        case .snareAlternate:
            let pos = snare.position(bar: bar, barBeat: barBeat)
            let on = ((pos.step + i) % 2 + 2) % 2 == 0
            return on ? decay(pos.since / (pos.interval * 1.4)) : 0
        case .steady:
            return 1
        case .breathe:
            return 0.5 - 0.5 * cos(2 * .pi * (b / max(cycle, 2) + Double(i) * 0.04))
        case .wave:
            return 0.5 + 0.5 * sin(2 * .pi * (b / max(cycle, 2) - Double(i) / nD))
        case .pulse:
            return decay(fmodPositive(b, 1))
        case .halfPulse:
            return decay(fmodPositive(b / 2, 1))
        case .barPulse:
            return decay(barBeat / 4) * 0.6 + 0.4 * decay(fmodPositive(barBeat, 1))
        case .backbeat:
            let beatInBar = Int(floor(barBeat))
            return beatInBar % 2 == 1 ? decay(barBeat - floor(barBeat)) : 0
        case .chase:
            let pos = fmodPositive(b * min(rate, 1), nD)
            var d = abs(pos - Double(i)); d = min(d, nD - d)
            return window(d, 1.6)
        case .bounce:
            let period = 2 * (nD - 1)
            let raw = fmodPositive(b * min(rate, 1) * 2, max(period, 1))
            let pos = raw <= nD - 1 ? raw : period - raw
            return window(pos - Double(i), 1.6)
        case .centerOut:
            let phase = fmodPositive(b * min(rate, 1) / 2, 1)
            return window(abs(x) - phase * 1.2, 0.55)
        case .alternate:
            // Odd/even swap every bar, crossfaded over the first beat of the bar.
            let on = (bar + i) % 2 == 0
            let prevOn = (bar - 1 + i) % 2 == 0
            let t = smoothstep(barBeat)
            return lerp(prevOn ? 1 : 0, on ? 1 : 0, t)
        }
    }

    /// Musical accent overlay (0...1) on the bar structure.
    static func accent(_ a: Accent, barBeat: Double, beat b: Double) -> Double {
        switch a {
        case .none: return 0
        case .downbeat: return barBeat < 1 ? decay(barBeat) : 0
        case .backbeat:
            let beatInBar = Int(floor(barBeat))
            return beatInBar % 2 == 1 ? decay(barBeat - floor(barBeat)) : 0
        case .everyBeat: return decay(fmodPositive(b, 1))
        }
    }

    static func l7Color(_ p: L7ColorPattern, palette: Palette, beat b: Double, barBeat: Double, bar: Int,
                        index i: Int, x: Double, fadeBeats: Double) -> RGB {
        switch p {
        case .uniformA: return palette.a
        case .uniformB: return palette.b
        case .split: return i % 2 == 0 ? palette.a : palette.b
        case .halves: return x < 0 ? palette.a : palette.b
        case .gradient: return palette.a.mix(palette.b, (x + 1) / 2)
        case .roll:
            let t = 0.5 + 0.5 * sin(2 * .pi * (b / 32 - Double(i) / 6))
            return palette.a.mix(palette.b, t)
        case .centerOut: return abs(x) < 0.5 ? palette.a : palette.b
        case .alternateBar:
            let cur = (bar + i) % 2 == 0 ? palette.a : palette.b
            let prev = (bar - 1 + i) % 2 == 0 ? palette.a : palette.b
            return prev.mix(cur, smoothstep(barBeat / max(fadeBeats, 0.25)))
        }
    }

    static func hybridColor(_ p: HybridColorPattern, palette: Palette, side: Int, row: Int) -> RGB {
        switch p {
        case .uniformA: return palette.a
        case .uniformB: return palette.b
        case .sides: return side < 0 ? palette.a : palette.b
        case .rows: return row % 2 == 0 ? palette.a : palette.b
        case .accentCenter: return row == 1 ? palette.accent : palette.a
        }
    }

    /// L7 aim (pan, tilt). x in -1...1 (left to right).
    static func l7Aim(_ m: L7Move, beat b: Double, index i: Int, x: Double, cycle: Double, amount: Double) -> (Double, Double) {
        let w = 2 * Double.pi * b / max(cycle, 4)
        switch m {
        case .up: return (0, 4)
        case .forward: return (0, 40)
        case .fan: return (x * 38 * amount, 26)
        case .vee: return (0, i % 2 == 0 ? 14 : 42)
        case .cross: return (-x * 32 * amount, 30)
        case .tiltWave: return (x * 12, 28 + 18 * amount * sin(w - Double(i) * 0.6))
        case .panSway: return ((x < 0 ? -1 : 1) * 26 * amount * sin(w), 32)
        case .fanBreath: return (x * 40 * amount * (0.5 + 0.5 * sin(w)), 22 + 8 * sin(w))
        case .circle:
            let ph = w + Double(i) * .pi / 3
            return (18 * amount * sin(ph), 32 + 12 * amount * cos(ph))
        }
    }

    /// Hybrid aim (pan, tilt). side -1 (left) / +1 (right), row 0 (upstage pair) ... 2 (downstage pair).
    static func hybridAim(_ m: HybridMove, beat b: Double, number n: Int, side: Int, row: Int,
                          cycle: Double, amount: Double) -> (Double, Double) {
        let s = Double(side), r = Double(row)
        let w = 2 * Double.pi * b / max(cycle, 4)
        switch m {
        case .vUp: return (s * 70, 14 + 8 * r)
        case .fan: return (s * (25 + 18 * r), 30)
        case .cross: return (-s * 55, 30 + 6 * r)
        case .forward: return (s * 8, 38)
        case .audience: return (s * (10 + 8 * r), 58)
        case .circle:
            let ph = w + Double(n) * .pi / 3
            return (s * 25 + 24 * amount * sin(ph), 34 + 14 * amount * cos(ph))
        case .figure8:
            let ph = w + (side < 0 ? 0 : .pi)
            return (s * 20 + 28 * amount * sin(ph), 34 + 12 * amount * sin(2 * ph))
        case .tiltWave:
            return (s * 40, 30 + 22 * amount * sin(w - r * 0.9))
        case .sweep:
            return (s * 40 * amount * sin(w), 38)
        case .ballyhoo:
            let k = Double(n) * 1.7
            let p = 34 * amount * (0.6 * sin(w * 0.5 + k) + 0.4 * sin(w * 0.8 + 2 * k))
            let t = 34 + 16 * amount * (0.6 * sin(w * 0.6 + 3 * k) + 0.4 * cos(w * 0.9 + k))
            return (s * 15 + p, t)
        }
    }

    static func applyBeam(_ beam: HybridBeam, gobo: Int, to s: inout FixtureState, side: Int) {
        let dir = Double(side)
        switch beam {
        case .wash:
            s.frost = 0.7
        case .softGobo:
            s.gobo = gobo; s.goboRotation = 0.15 * dir; s.frost = 0.25
        case .beam:
            break
        case .prism:
            s.prism = 1; s.prismRotation = 0.18 * dir
        case .goboSpin:
            s.gobo = gobo; s.goboRotation = 0.25 * dir
        case .goboPrism:
            s.gobo = gobo; s.goboRotation = 0.2 * dir; s.prism = 1; s.prismRotation = -0.12 * dir
        case .linearPrism:
            s.prism = 2; s.prismRotation = 0.1 * dir
        }
    }
}
