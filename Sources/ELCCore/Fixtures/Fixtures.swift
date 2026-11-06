import Foundation

public enum FixtureKind: String, Codable, CaseIterable, Sendable {
    case focusFlexL7 = "ADJ Focus Flex L7 (16ch Basic)"
    case focusHybrid = "ADJ Focus Hybrid (19ch)"

    public var channelCount: Int {
        switch self {
        case .focusFlexL7: return 16
        case .focusHybrid: return 19
        }
    }

    public var shortName: String {
        switch self {
        case .focusFlexL7: return "Flex L7"
        case .focusHybrid: return "Hybrid"
        }
    }

    public var defaultPanRange: Double { 540 }
    public var defaultTiltRange: Double { 270 }
}

/// Shutter / strobe behaviour, shared by both fixture types (same DMX ranges).
public enum Shutter: Equatable, Sendable {
    case open
    case closed
    case strobe(Double)        // 0 slow ... 1 fast
    case pulse(Double)         // 0 slow ... 1 fast
    case randomStrobe(Double)  // 0 slow ... 1 fast

    var dmx: UInt8 {
        func range(_ lo: Int, _ hi: Int, _ t: Double) -> UInt8 {
            UInt8(clamp(lo + Int((Double(hi - lo) * clamp(t, 0, 1)).rounded()), lo, hi))
        }
        switch self {
        case .open: return 48
        case .closed: return 0
        case .strobe(let t): return range(64, 95, t)
        case .pulse(let t): return range(128, 159, t)
        case .randomStrobe(let t): return range(192, 223, t)
        }
    }
}

/// Abstract, fixture independent state produced by the show engine.
public struct FixtureState: Equatable, Sendable {
    public var intensity: Double = 0          // 0...1
    public var color: RGB = .white            // L7 colour (RGB + lime derived)
    public var hybridColor: HybridColor? = nil // explicit wheel slot for the Hybrid (else nearest to `color`)
    public var pan: Double = 0                // degrees, 0 = facing audience, + = to the right (as seen on the plot)
    public var tilt: Double = 30              // degrees from vertical, + = toward the audience, - = toward LED wall
    public var zoom: Double = 0.5             // 0 = narrow, 1 = wide
    public var shutter: Shutter = .open
    // Hybrid only
    public var gobo: Int = 0                  // rotating gobo 0 = open, 1...8
    public var goboShake: Double? = nil       // shake speed 0...1 for the selected rotating gobo
    public var goboRotation: Double = 0       // -1 (ccw fast) ... 0 (stop) ... 1 (cw fast)
    public var staticGobo: Int = 0            // 0 = open, 1...15
    public var prism: Int = 0                 // 0 = none, 1 = 8 facet circular, 2 = 6 facet linear
    public var prismRotation: Double = 0      // -1 ... 1
    public var frost: Double = 0              // 0...1
    public var focus: Double? = nil           // nil = calibrated default
    public var moveSmoothing: Double = 0      // 0 = fixture max speed, 1 = very slow internal smoothing

    public init() {}
}

public struct FixtureCalibration: Codable, Equatable, Sendable {
    /// Fixture pan angle (degrees over full pan range) where the head faces the audience.
    public var panHomeDeg: Double
    public var panInvert: Bool
    /// Fixture tilt angle (degrees over full tilt range) where the beam points straight up.
    public var tiltUpDeg: Double
    /// Flip when tilting "forward" moves the beam towards the LED wall.
    public var tiltInvert: Bool
    /// How far the beam may lean back towards the LED wall (degrees from vertical).
    public var backLimitDeg: Double
    /// How far the beam may lean forward towards the audience (degrees from vertical, 90 = horizontal).
    public var forwardLimitDeg: Double
    /// Maximum pan offset either side of home (degrees).
    public var panLimitDeg: Double
    public var panRangeDeg: Double
    public var tiltRangeDeg: Double
    /// Default focus (Hybrid only) 0...1
    public var focus: Double

    public init(panHomeDeg: Double = 270, panInvert: Bool = false, tiltUpDeg: Double = 135, tiltInvert: Bool = false,
                backLimitDeg: Double = 0, forwardLimitDeg: Double = 80, panLimitDeg: Double = 110,
                panRangeDeg: Double = 540, tiltRangeDeg: Double = 270, focus: Double = 0.5) {
        self.panHomeDeg = panHomeDeg; self.panInvert = panInvert
        self.tiltUpDeg = tiltUpDeg; self.tiltInvert = tiltInvert
        self.backLimitDeg = backLimitDeg; self.forwardLimitDeg = forwardLimitDeg
        self.panLimitDeg = panLimitDeg
        self.panRangeDeg = panRangeDeg; self.tiltRangeDeg = tiltRangeDeg
        self.focus = focus
    }
}

public struct FixturePatch: Codable, Equatable, Identifiable, Sendable {
    public var id: Int                 // fixture number 1...12
    public var name: String
    public var kind: FixtureKind
    public var universe: UInt16
    public var address: Int            // 1-based DMX start address
    public var plotX: Double           // 0...1, plot (top view) position, left -> right
    public var plotY: Double           // 0...1, plot (top view) position, LED wall (0) -> audience (1)
    public var calibration: FixtureCalibration

    public init(id: Int, name: String, kind: FixtureKind, universe: UInt16, address: Int,
                plotX: Double, plotY: Double, calibration: FixtureCalibration) {
        self.id = id; self.name = name; self.kind = kind; self.universe = universe; self.address = address
        self.plotX = plotX; self.plotY = plotY; self.calibration = calibration
    }
}

public struct Rig: Codable, Equatable, Sendable {
    public var fixtures: [FixturePatch]

    public init(fixtures: [FixturePatch]) { self.fixtures = fixtures }

    public var l7s: [FixturePatch] { fixtures.filter { $0.kind == .focusFlexL7 } }
    public var hybrids: [FixturePatch] { fixtures.filter { $0.kind == .focusHybrid } }
    public var universes: [UInt16] { Array(Set(fixtures.map { $0.universe })).sorted() }

    /// The ELC rig as drawn on the plot:
    /// 6x Flex L7 in a line in front of the LED wall (numbered left to right),
    /// 6x Focus Hybrid in a V (1/2 upstage pair, 3/4 middle, 5/6 downstage; odd = left).
    public static func elcDefault(universe: UInt16 = 1) -> Rig {
        var f: [FixturePatch] = []
        // Plot coordinates taken from the top view (1704 x 1004 px).
        let l7X: [Double] = [300, 500, 710, 1000, 1200, 1400]
        for i in 0..<6 {
            f.append(FixturePatch(id: i + 1, name: "L7 \(i + 1)", kind: .focusFlexL7, universe: universe,
                                  address: 1 + 16 * i, plotX: l7X[i] / 1704, plotY: 192 / 1004,
                                  calibration: FixtureCalibration(backLimitDeg: 0, forwardLimitDeg: 80)))
        }
        let hyb: [(Double, Double)] = [(620, 400), (1100, 400), (400, 607), (1310, 605), (205, 812), (1525, 815)]
        for i in 0..<6 {
            f.append(FixturePatch(id: 7 + i, name: "Hybrid \(i + 1)", kind: .focusHybrid, universe: universe,
                                  address: 97 + 19 * i, plotX: hyb[i].0 / 1704, plotY: hyb[i].1 / 1004,
                                  calibration: FixtureCalibration(backLimitDeg: 5, forwardLimitDeg: 80)))
        }
        return Rig(fixtures: f)
    }

    /// Returns a list of human readable problems (overlaps, out of range addresses).
    public func validate() -> [String] {
        var problems: [String] = []
        var used: [UInt16: [(Int, ClosedRange<Int>)]] = [:]
        for fx in fixtures {
            let r = fx.address...(fx.address + fx.kind.channelCount - 1)
            if fx.address < 1 || r.upperBound > 512 {
                problems.append("\(fx.name): address \(fx.address) does not fit in a universe")
            }
            for (other, otherRange) in used[fx.universe, default: []] where otherRange.overlaps(r) {
                problems.append("\(fx.name) overlaps fixture \(other) in universe \(fx.universe)")
            }
            used[fx.universe, default: []].append((fx.id, r))
        }
        return problems
    }
}

// MARK: - Pan / tilt geometry

public enum BeamGeometry {
    /// Clamps an abstract aim so the beam never points at the LED wall (or too far into the audience).
    /// `pan` 0 = facing audience; `tilt` measured from vertical, positive = leaning in the pan direction.
    public static func safeAim(pan: Double, tilt: Double, calibration c: FixtureCalibration) -> (pan: Double, tilt: Double) {
        let p = clamp(pan, -c.panLimitDeg, c.panLimitDeg)
        var t = clamp(tilt, -c.backLimitDeg, c.forwardLimitDeg)
        // Forward component of the beam direction (towards the audience).
        let cp = cos(degToRad(p))
        let forward = sin(degToRad(t)) * cp
        let minForward = -sin(degToRad(c.backLimitDeg))
        if forward < minForward, abs(cp) > 1e-6 {
            // Leaning towards the wall: reduce the lean until it is within the back limit.
            let s = clamp(minForward / cp, -1, 1)
            t = radToDeg(asin(s))
        }
        return (p, t)
    }

    /// Converts a safe abstract aim into 8 bit DMX pan / tilt values.
    public static func dmx(pan: Double, tilt: Double, calibration c: FixtureCalibration) -> (pan: UInt8, tilt: UInt8) {
        let aim = safeAim(pan: pan, tilt: tilt, calibration: c)
        let panDeg = c.panHomeDeg + (c.panInvert ? -aim.pan : aim.pan)
        let tiltDeg = c.tiltUpDeg + (c.tiltInvert ? -aim.tilt : aim.tilt)
        let pv = clamp(panDeg / c.panRangeDeg, 0, 1)
        let tv = clamp(tiltDeg / c.tiltRangeDeg, 0, 1)
        return (toByte(pv), toByte(tv))
    }
}

// MARK: - DMX encoders

public enum FixtureEncoder {
    /// Encodes a fixture state into its DMX channel values (index 0 = the fixture's first channel).
    public static func encode(_ s: FixtureState, patch: FixturePatch) -> [UInt8] {
        switch patch.kind {
        case .focusFlexL7: return encodeL7(s, patch.calibration)
        case .focusHybrid: return encodeHybrid(s, patch.calibration)
        }
    }

    /// ADJ Focus Flex L7, 16 channel "Basic" mode.
    static func encodeL7(_ s: FixtureState, _ c: FixtureCalibration) -> [UInt8] {
        var ch = [UInt8](repeating: 0, count: 16)
        let pt = BeamGeometry.dmx(pan: s.pan, tilt: s.tilt, calibration: c)
        ch[0] = pt.pan                                   // 1  Pan
        ch[1] = pt.tilt                                  // 2  Tilt
        // RGB + Lime: route the yellow/green part of the colour into the lime emitter.
        let r = clamp(s.color.r, 0, 1), g = clamp(s.color.g, 0, 1), b = clamp(s.color.b, 0, 1)
        let lime = clamp(min(r, g) * 0.8 + max(0, g - r - b) * 0.25, 0, 1)
        ch[2] = toByte(r)                                // 3  Red
        ch[3] = toByte(g)                                // 4  Green
        ch[4] = toByte(b)                                // 5  Blue
        ch[5] = toByte(lime)                             // 6  Lime
        ch[6] = 0                                        // 7  CT presets: no function
        ch[7] = 0                                        // 8  Colour macros: off
        ch[8] = s.intensity > 0 ? s.shutter.dmx : 0      // 9  Shutter / strobe
        ch[9] = toByte(s.intensity)                      // 10 Dimmer
        ch[10] = toByte(1 - clamp(s.zoom, 0, 1))         // 11 Zoom (wide -> narrow)
        ch[11] = 0                                       // 12 Internal programs: none
        ch[12] = 0                                       // 13 Program speed
        ch[13] = 0                                       // 14 Program fade
        ch[14] = toByte(clamp(s.moveSmoothing, 0, 1) * 0.6) // 15 Pan/tilt speed (max -> min)
        ch[15] = 0                                       // 16 Special functions: none
        return ch
    }

    /// ADJ Focus Hybrid, 19 channel mode.
    static func encodeHybrid(_ s: FixtureState, _ c: FixtureCalibration) -> [UInt8] {
        var ch = [UInt8](repeating: 0, count: 19)
        let pt = BeamGeometry.dmx(pan: s.pan, tilt: s.tilt, calibration: c)
        ch[0] = pt.pan                                    // 1  Pan
        ch[1] = pt.tilt                                   // 2  Tilt
        ch[2] = (s.hybridColor ?? HybridColor.nearest(to: s.color)).dmx // 3 Colour wheel
        // 4 Rotating gobo wheel
        let g = clamp(s.gobo, 0, 8)
        if g == 0 {
            ch[3] = 0
        } else if let shake = s.goboShake {
            ch[3] = UInt8(78 + 14 * (g - 1) + Int((clamp(shake, 0, 1) * 13).rounded()))
        } else {
            ch[3] = UInt8(6 + 9 * (g - 1) + 4)
        }
        // 5 Gobo rotation: 128-189 CW fast->slow, 190-192 stop, 193-255 CCW slow->fast
        let gr = clamp(s.goboRotation, -1, 1)
        if g == 0 || abs(gr) < 0.02 {
            ch[4] = 191
        } else if gr > 0 {
            ch[4] = UInt8(189 - Int((gr * 61).rounded()))
        } else {
            ch[4] = UInt8(193 + Int((-gr * 62).rounded()))
        }
        // 6 Static gobo wheel
        let sg = clamp(s.staticGobo, 0, 15)
        ch[5] = sg == 0 ? 0 : UInt8(10 + 4 * (sg - 1) + 2)
        ch[6] = s.intensity > 0 ? s.shutter.dmx : 0       // 7 Shutter / strobe
        ch[7] = toByte(s.intensity)                       // 8 Dimmer
        // 9/10 Prism 1 (8 facet circular) + rotation, 12/13 Prism 2 (6 facet linear) + rotation
        func prismRot(_ v: Double) -> UInt8 {
            let r = clamp(v, -1, 1)
            if abs(r) < 0.02 { return 0 }
            return r > 0 ? UInt8(191 - Int((r * 62).rounded())) : UInt8(193 + Int((-r * 62).rounded()))
        }
        ch[8] = s.prism == 1 ? 128 : 0
        ch[9] = s.prism == 1 ? prismRot(s.prismRotation) : 0
        ch[10] = 0                                        // 11 Prism 1 / gobo macros: off
        ch[11] = s.prism == 2 ? 128 : 0
        ch[12] = s.prism == 2 ? prismRot(s.prismRotation) : 0
        ch[13] = 0                                        // 14 Prism 2 / gobo macros: off
        ch[14] = toByte(s.focus ?? c.focus)               // 15 Focus
        ch[15] = toByte(clamp(s.zoom, 0, 1))              // 16 Zoom (narrow -> wide)
        ch[16] = toByte(clamp(s.frost, 0, 1))             // 17 Frost
        ch[17] = UInt8(Int((clamp(s.moveSmoothing, 0, 1) * 150).rounded())) // 18 Pan/tilt speed (fast -> slow)
        ch[18] = 0                                        // 19 Special functions: none
        return ch
    }

    /// Builds full 512-slot frames for every universe used by the rig.
    public static func frames(rig: Rig, states: [Int: FixtureState]) -> [UInt16: [UInt8]] {
        var out: [UInt16: [UInt8]] = [:]
        for u in rig.universes { out[u] = [UInt8](repeating: 0, count: 512) }
        for fx in rig.fixtures {
            guard let st = states[fx.id] else { continue }
            let values = encode(st, patch: fx)
            let start = fx.address - 1
            guard start >= 0 else { continue }
            for (i, v) in values.enumerated() where start + i < 512 {
                out[fx.universe]![start + i] = v
            }
        }
        return out
    }
}
