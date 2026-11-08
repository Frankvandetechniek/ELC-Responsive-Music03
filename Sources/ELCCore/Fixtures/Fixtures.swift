import Foundation

public enum FixtureKind: String, Codable, CaseIterable, Sendable {
    case focusFlexL7 = "ADJ Focus Flex L7 (50ch Extended 7)"
    case focusHybrid = "ADJ Focus Hybrid (25ch)"

    public var channelCount: Int {
        switch self {
        case .focusFlexL7: return 50
        case .focusHybrid: return 25
        }
    }

    /// Number of individually controllable pixels (L7: 7 RGB+Lime cells).
    public var pixelCount: Int { self == .focusFlexL7 ? 7 : 1 }

    /// Tolerant decoding: configurations saved with older channel modes map onto the current kinds.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let k = FixtureKind(rawValue: raw) { self = k }
        else if raw.contains("L7") { self = .focusFlexL7 }
        else if raw.contains("Hybrid") { self = .focusHybrid }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown fixture \(raw)")) }
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
    /// L7 only: per-pixel colour (7 cells, left → right as seen on the plot). `nil` = all pixels `color`.
    /// Pixel colours carry their own brightness; the fixture dimmer (`intensity`) scales all of them.
    public var pixels: [RGB]? = nil
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
                                  address: 1 + 50 * i, plotX: l7X[i] / 1704, plotY: 192 / 1004,
                                  calibration: FixtureCalibration(backLimitDeg: 0, forwardLimitDeg: 80)))
        }
        let hyb: [(Double, Double)] = [(620, 400), (1100, 400), (400, 607), (1310, 605), (205, 812), (1525, 815)]
        for i in 0..<6 {
            f.append(FixturePatch(id: 7 + i, name: "Hybrid \(i + 1)", kind: .focusHybrid, universe: universe,
                                  address: 301 + 25 * i, plotX: hyb[i].0 / 1704, plotY: hyb[i].1 / 1004,
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

    /// Converts a safe abstract aim into 16 bit DMX pan / tilt values (coarse, fine).
    public static func dmx16(pan: Double, tilt: Double, calibration c: FixtureCalibration) -> (pan: UInt16, tilt: UInt16) {
        let aim = safeAim(pan: pan, tilt: tilt, calibration: c)
        let panDeg = c.panHomeDeg + (c.panInvert ? -aim.pan : aim.pan)
        let tiltDeg = c.tiltUpDeg + (c.tiltInvert ? -aim.tilt : aim.tilt)
        return (toWord(clamp(panDeg / c.panRangeDeg, 0, 1)), toWord(clamp(tiltDeg / c.tiltRangeDeg, 0, 1)))
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

    @inline(__always) static func put16(_ ch: inout [UInt8], _ index: Int, _ v: UInt16) {
        ch[index] = UInt8(v >> 8)
        ch[index + 1] = UInt8(v & 0xFF)
    }

    /// RGB → (R, G, B, Lime): the yellow/green part of the colour also drives the lime emitter.
    @inline(__always) static func rgbl(_ c: RGB) -> (UInt8, UInt8, UInt8, UInt8) {
        let r = clamp(c.r, 0, 1), g = clamp(c.g, 0, 1), b = clamp(c.b, 0, 1)
        let lime = clamp(min(r, g) * 0.8 + max(0, g - r - b) * 0.25, 0, 1)
        return (toByte(r), toByte(g), toByte(b), toByte(lime))
    }

    /// ADJ Focus Flex L7, 50 channel "Extended 7" mode (7 RGB+Lime pixels, 16 bit pan/tilt/dimmer/zoom).
    static func encodeL7(_ s: FixtureState, _ c: FixtureCalibration) -> [UInt8] {
        var ch = [UInt8](repeating: 0, count: 50)
        let pt = BeamGeometry.dmx16(pan: s.pan, tilt: s.tilt, calibration: c)
        put16(&ch, 0, pt.pan)                            // 1/2   Pan, pan fine
        put16(&ch, 2, pt.tilt)                           // 3/4   Tilt, tilt fine
        for p in 0..<7 {                                 // 5-32  Pixel 1-7: R, G, B, Lime
            let col = s.pixels.map { $0.indices.contains(p) ? $0[p] : s.color } ?? s.color
            let v = rgbl(col)
            ch[4 + p * 4] = v.0; ch[5 + p * 4] = v.1; ch[6 + p * 4] = v.2; ch[7 + p * 4] = v.3
        }
        ch[32] = 0                                       // 33    Colour temperature linear: off
        ch[33] = 0                                       // 34    CT presets: no function
        ch[34] = 0                                       // 35    Virtual foreground wheel: open
        ch[35] = 0                                       // 36    Virtual background wheel: open
        ch[36] = 0                                       // 37    CT red → green: no function
        ch[37] = 0                                       // 38    Colour macros: off
        ch[38] = s.intensity > 0 ? s.shutter.dmx : 0     // 39    Shutter / strobe
        put16(&ch, 39, toWord(s.intensity))              // 40/41 Dimmer, dimmer fine
        put16(&ch, 41, toWord(1 - clamp(s.zoom, 0, 1)))  // 42/43 Zoom (wide → narrow), fine
        ch[43] = 0                                       // 44    Dim mode: unit setting
        ch[44] = 30                                      // 45    Dim curve: linear (the engine shapes its own fades)
        ch[45] = 0                                       // 46    Internal programs: none
        ch[46] = 0                                       // 47    Program speed
        ch[47] = 0                                       // 48    Program fade
        ch[48] = toByte(clamp(s.moveSmoothing, 0, 1) * 0.6) // 49 Pan/tilt speed (max → min)
        ch[49] = 0                                       // 50    Special functions: none
        return ch
    }

    /// ADJ Focus Hybrid, 25 channel mode (16 bit pan/tilt, dimmer fine, zoom fine).
    static func encodeHybrid(_ s: FixtureState, _ c: FixtureCalibration) -> [UInt8] {
        var ch = [UInt8](repeating: 0, count: 25)
        let pt = BeamGeometry.dmx16(pan: s.pan, tilt: s.tilt, calibration: c)
        put16(&ch, 0, pt.pan)                             // 1/2  Pan, pan fine
        put16(&ch, 2, pt.tilt)                            // 3/4  Tilt, tilt fine
        ch[4] = (s.hybridColor ?? HybridColor.nearest(to: s.color)).dmx // 5 Colour wheel
        // 6 Rotating gobo wheel
        let g = clamp(s.gobo, 0, 8)
        if g == 0 {
            ch[5] = 0
        } else if let shake = s.goboShake {
            ch[5] = UInt8(78 + 14 * (g - 1) + Int((clamp(shake, 0, 1) * 13).rounded()))
        } else {
            ch[5] = UInt8(6 + 9 * (g - 1) + 4)
        }
        // 7 Gobo rotation: 128-189 CW fast->slow, 190-192 stop, 193-255 CCW slow->fast
        let gr = clamp(s.goboRotation, -1, 1)
        if g == 0 || abs(gr) < 0.02 {
            ch[6] = 191
        } else if gr > 0 {
            ch[6] = UInt8(189 - Int((gr * 61).rounded()))
        } else {
            ch[6] = UInt8(193 + Int((-gr * 62).rounded()))
        }
        // 8 Static gobo wheel
        let sg = clamp(s.staticGobo, 0, 15)
        ch[7] = sg == 0 ? 0 : UInt8(10 + 4 * (sg - 1) + 2)
        ch[8] = s.intensity > 0 ? s.shutter.dmx : 0       // 9 Shutter / strobe
        put16(&ch, 9, toWord(s.intensity))                // 10/11 Dimmer, dimmer fine
        func prismRot(_ v: Double) -> UInt8 {
            let r = clamp(v, -1, 1)
            if abs(r) < 0.02 { return 0 }
            return r > 0 ? UInt8(191 - Int((r * 62).rounded())) : UInt8(193 + Int((-r * 62).rounded()))
        }
        ch[11] = s.prism == 1 ? 128 : 0                   // 12 Prism 1 (8 facet circular)
        ch[12] = s.prism == 1 ? prismRot(s.prismRotation) : 0 // 13 Prism 1 index / rotation
        ch[13] = 0                                        // 14 Prism 1 / gobo macros: off
        ch[14] = s.prism == 2 ? 128 : 0                   // 15 Prism 2 (6 facet linear)
        ch[15] = s.prism == 2 ? prismRot(s.prismRotation) : 0 // 16 Prism 2 index / rotation
        ch[16] = 0                                        // 17 Prism 2 / gobo macros: off
        ch[17] = toByte(s.focus ?? c.focus)               // 18 Focus
        put16(&ch, 18, toWord(clamp(s.zoom, 0, 1)))       // 19/20 Zoom (narrow → wide), fine
        ch[20] = toByte(clamp(s.frost, 0, 1))             // 21 Frost
        ch[21] = 0                                        // 22 Dimmer mode: unit setting
        ch[22] = 30                                       // 23 Dim curve: linear
        ch[23] = UInt8(Int((clamp(s.moveSmoothing, 0, 1) * 150).rounded())) // 24 Pan/tilt speed (fast -> slow)
        ch[24] = 0                                        // 25 Special functions: none
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
