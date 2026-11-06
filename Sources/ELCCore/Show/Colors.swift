import Foundation

public struct RGB: Codable, Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    public static let black = RGB(0, 0, 0)
    public static let white = RGB(1, 1, 1)

    // ELC brand colours
    public static let brandGreen = RGB(0.0, 1.0, 0.18)
    public static let brandMagenta = RGB(1.0, 0.0, 0.78)
    public static let brandPurple = RGB(0.55, 0.0, 1.0)

    // Secondary colours
    public static let red = RGB(1, 0, 0)
    public static let orange = RGB(1, 0.35, 0)
    public static let amber = RGB(1, 0.55, 0.05)
    public static let yellow = RGB(1, 0.85, 0)
    public static let cyan = RGB(0, 0.85, 1)
    public static let blue = RGB(0, 0.15, 1)
    public static let deepBlue = RGB(0.1, 0, 1)
    public static let lightBlue = RGB(0.45, 0.75, 1)
    public static let lime = RGB(0.6, 1, 0)
    public static let pink = RGB(1, 0.3, 0.6)

    public func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(lerp(r, other.r, t), lerp(g, other.g, t), lerp(b, other.b, t))
    }

    public func scaled(_ k: Double) -> RGB { RGB(r * k, g * k, b * k) }

    /// Hue (0..<360), saturation (0...1), value (0...1).
    public var hsv: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h = 0.0
        if d > 1e-9 {
            if mx == r { h = 60 * fmodPositive((g - b) / d, 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}

/// Colour wheel slots of the ADJ Focus Hybrid (19ch mode, channel 3).
public enum HybridColor: String, Codable, CaseIterable, Sendable {
    case open, red, blue, green, yellow, orange, purple, magenta, darkBlue, lightBlue, lightGreen, cto

    /// Centre DMX value of the slot.
    public var dmx: UInt8 {
        switch self {
        case .open: return 4
        case .red: return 11
        case .blue: return 16
        case .green: return 21
        case .yellow: return 26
        case .orange: return 31
        case .purple: return 36
        case .magenta: return 41
        case .darkBlue: return 46
        case .lightBlue: return 51
        case .lightGreen: return 56
        case .cto: return 61
        }
    }

    /// Approximate output colour (for the visualiser and colour matching).
    public var rgb: RGB {
        switch self {
        case .open: return .white
        case .red: return .red
        case .blue: return .blue
        case .green: return RGB(0, 1, 0.1)
        case .yellow: return .yellow
        case .orange: return .orange
        case .purple: return .brandPurple
        case .magenta: return .brandMagenta
        case .darkBlue: return .deepBlue
        case .lightBlue: return .lightBlue
        case .lightGreen: return RGB(0.55, 1, 0.45)
        case .cto: return RGB(1, 0.78, 0.5)
        }
    }

    /// Nearest wheel slot for an arbitrary RGB colour.
    public static func nearest(to c: RGB) -> HybridColor {
        let (h, s, v) = c.hsv
        if v < 0.01 || s < 0.22 { return .open }
        var best = HybridColor.open
        var bestScore = Double.greatestFiniteMagnitude
        for slot in HybridColor.allCases where slot != .open && slot != .cto {
            let (sh, ss, _) = slot.rgb.hsv
            var dh = abs(sh - h); if dh > 180 { dh = 360 - dh }
            let score = dh + abs(ss - s) * 60
            if score < bestScore { bestScore = score; best = slot }
        }
        return best
    }
}

/// A palette: the colours for the "A" and "B" side of a look plus an accent.
public struct Palette: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var a: RGB
    public var b: RGB
    public var accent: RGB
    public var isBrand: Bool

    public init(name: String, a: RGB, b: RGB, accent: RGB, isBrand: Bool) {
        self.name = name; self.a = a; self.b = b; self.accent = accent; self.isBrand = isBrand
    }

    public static let brand = Palette(name: "ELC Green / Magenta", a: .brandGreen, b: .brandMagenta, accent: .white, isBrand: true)
    public static let brandPurple = Palette(name: "ELC Green / Purple", a: .brandGreen, b: .brandPurple, accent: .brandMagenta, isBrand: true)
    public static let brandMagentaPurple = Palette(name: "Magenta / Purple", a: .brandMagenta, b: .brandPurple, accent: .brandGreen, isBrand: true)
    public static let brandGreenWhite = Palette(name: "Green / White", a: .brandGreen, b: .white, accent: .brandMagenta, isBrand: true)
    public static let brandMagentaWhite = Palette(name: "Magenta / White", a: .brandMagenta, b: .white, accent: .brandGreen, isBrand: true)

    public static let ocean = Palette(name: "Ocean", a: .cyan, b: .deepBlue, accent: .brandMagenta, isBrand: false)
    public static let sunset = Palette(name: "Sunset", a: .orange, b: .brandMagenta, accent: .yellow, isBrand: false)
    public static let fire = Palette(name: "Fire", a: .red, b: .amber, accent: .yellow, isBrand: false)
    public static let ice = Palette(name: "Ice", a: .lightBlue, b: .white, accent: .cyan, isBrand: false)
    public static let toxic = Palette(name: "Toxic", a: .lime, b: .brandPurple, accent: .brandGreen, isBrand: false)
    public static let warm = Palette(name: "Warm White", a: RGB(1, 0.72, 0.4), b: .amber, accent: .white, isBrand: false)

    public static let brandPalettes: [Palette] = [.brand, .brandPurple, .brandMagentaPurple, .brandGreenWhite, .brandMagentaWhite]
    public static let extraPalettes: [Palette] = [.ocean, .sunset, .fire, .ice, .toxic]
    public static let all: [Palette] = brandPalettes + extraPalettes + [.warm]
}

public enum ColorPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case brandOnly = "Brand only"
    case brandMostly = "Mostly brand"
    case anything = "All colours"
    public var id: String { rawValue }
}
