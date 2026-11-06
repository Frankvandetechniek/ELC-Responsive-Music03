// Generates the AppIcon.iconset PNGs: usage `swift scripts/make_icon.swift <output.iconset>`
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)
    NSColor(white: 0.06, alpha: 1).setFill()
    path.fill()
    path.addClip()
    let green = NSColor(red: 0, green: 0.95, blue: 0.3, alpha: 1)
    let magenta = NSColor(red: 1, green: 0.05, blue: 0.75, alpha: 1)
    // Beams from the bottom fanning upwards
    let beams: [(CGFloat, CGFloat, NSColor)] = [(0.3, -0.25, green), (0.42, -0.08, magenta), (0.58, 0.08, green), (0.7, 0.25, magenta)]
    for (x, lean, c) in beams {
        let base = NSPoint(x: s * x, y: s * 0.2)
        let top = NSPoint(x: s * (x + lean), y: s * 0.95)
        let w = s * 0.07
        let beam = NSBezierPath()
        beam.move(to: NSPoint(x: base.x - w * 0.15, y: base.y))
        beam.line(to: NSPoint(x: top.x - w, y: top.y))
        beam.line(to: NSPoint(x: top.x + w, y: top.y))
        beam.line(to: NSPoint(x: base.x + w * 0.15, y: base.y))
        beam.close()
        let g = NSGradient(starting: c.withAlphaComponent(0.95), ending: c.withAlphaComponent(0.05))
        g?.draw(in: beam, angle: 90)
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: base.x - w * 0.6, y: base.y - w * 0.6, width: w * 1.2, height: w * 1.2)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    if let d = render(px) { try? d.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png")) }
}
