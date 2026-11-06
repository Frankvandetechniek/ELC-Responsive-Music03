import ELCCore
import SwiftUI

/// Top view of the rig, laid out like the plot: LED wall at the top, L7 line in front of it,
/// Hybrids in a V towards the audience. Beams are drawn as their projection on the floor plan.
struct StageView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(title: "Stage (top view)", trailing: AnyView(
            HStack(spacing: 8) {
                Text(model.status.modeName).font(.caption.bold())
                if !model.status.special.isEmpty {
                    Text(model.status.special)
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.magenta.opacity(0.7)))
                }
            })) {
            GeometryReader { geo in
                Canvas { ctx, size in
                    draw(ctx: ctx, size: size)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(1704.0 / 1004.0, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        // LED wall
        let wallY = h * 0.085
        let wallRect = CGRect(x: w * 0.12, y: wallY - h * 0.025, width: w * 0.76, height: h * 0.03)
        ctx.fill(Path(roundedRect: wallRect, cornerRadius: 3), with: .color(Color(white: 0.18)))
        ctx.draw(Text("LED WALL").font(.system(size: 9, weight: .bold)).foregroundColor(Color(white: 0.5)),
                 at: CGPoint(x: w / 2, y: wallY - h * 0.01))
        ctx.draw(Text("AUDIENCE ↓").font(.system(size: 9, weight: .bold)).foregroundColor(Color(white: 0.35)),
                 at: CGPoint(x: w / 2, y: h * 0.96))

        // Beams first (so fixtures are drawn on top)
        for fx in model.rig.fixtures {
            guard let s = model.fixtureStates[fx.id], s.intensity > 0.01 else { continue }
            let p = CGPoint(x: fx.plotX * w, y: fx.plotY * h)
            let color = displayColor(s, fx)
            let lean = sin(degToRad(s.tilt))
            // Unit direction of the lean on the floor plan (+y = towards the audience).
            let sign: Double = lean < 0 ? -1 : 1
            let dirX = sin(degToRad(s.pan)) * sign
            let dirY = cos(degToRad(s.pan)) * sign
            let len = Double(h) * (0.06 + 0.5 * abs(lean))
            let end = CGPoint(x: p.x + CGFloat(dirX * len), y: p.y + CGFloat(dirY * len))
            let spread = CGFloat(0.02 + 0.09 * s.zoom) * CGFloat(len)
            let ang = atan2(end.y - p.y, end.x - p.x)
            let nx = -sin(ang) * spread, ny = cos(ang) * spread
            var cone = Path()
            cone.move(to: p)
            cone.addLine(to: CGPoint(x: end.x + nx, y: end.y + ny))
            cone.addLine(to: CGPoint(x: end.x - nx, y: end.y - ny))
            cone.closeSubpath()
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [color.opacity(0.85 * s.intensity), color.opacity(0)]),
                startPoint: p, endPoint: end)
            if abs(lean) > 0.05 { ctx.fill(cone, with: shading) }
            // Halo = light going up
            let halo = CGFloat(10 + 26 * s.intensity * (1 - abs(lean)))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.6 * s.intensity), color.opacity(0)]),
                                           center: p, startRadius: 0, endRadius: halo))
        }

        // Fixtures
        for fx in model.rig.fixtures {
            let s = model.fixtureStates[fx.id] ?? FixtureState()
            let p = CGPoint(x: fx.plotX * w, y: fx.plotY * h)
            let color = displayColor(s, fx)
            let lit = color.opacity(0.25 + 0.75 * s.intensity)
            var strobe = false
            if case .strobe = s.shutter { strobe = s.intensity > 0 }
            if fx.kind == .focusFlexL7 {
                let rw = w * 0.07, rh = h * 0.035
                let r = CGRect(x: p.x - rw / 2, y: p.y - rh / 2, width: rw, height: rh)
                ctx.fill(Path(roundedRect: r, cornerRadius: rh / 2), with: .color(Color(white: 0.12)))
                for k in 0..<7 {
                    let cx = r.minX + rw * (CGFloat(k) + 0.5) / 7
                    let d = rh * 0.55
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - d / 2, y: p.y - d / 2, width: d, height: d)),
                             with: .color(s.intensity > 0.01 ? lit : Color(white: 0.25)))
                }
                ctx.stroke(Path(roundedRect: r, cornerRadius: rh / 2), with: .color(strobe ? .white : Color(white: 0.35)),
                           lineWidth: strobe ? 2 : 1)
            } else {
                let d = h * 0.075
                let r = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
                ctx.fill(Path(ellipseIn: r), with: .color(Color(white: 0.12)))
                let inner = r.insetBy(dx: d * 0.22, dy: d * 0.22)
                ctx.fill(Path(ellipseIn: inner), with: .color(s.intensity > 0.01 ? lit : Color(white: 0.25)))
                ctx.stroke(Path(ellipseIn: r), with: .color(strobe ? .white : Color(white: 0.35)), lineWidth: strobe ? 2 : 1)
                if s.gobo > 0 || s.prism > 0 || s.frost > 0.3 {
                    var tag = ""
                    if s.gobo > 0 { tag += "G\(s.gobo)" }
                    if s.prism > 0 { tag += (tag.isEmpty ? "" : " ") + "P" }
                    if s.frost > 0.3 { tag += (tag.isEmpty ? "" : " ") + "F" }
                    ctx.draw(Text(tag).font(.system(size: 8)).foregroundColor(Color(white: 0.6)),
                             at: CGPoint(x: p.x, y: r.maxY + 8))
                }
            }
            let label = fx.kind == .focusFlexL7 ? "\(fx.id)" : "H\(fx.id - 6)"
            ctx.draw(Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(white: 0.7)),
                     at: CGPoint(x: p.x - (fx.kind == .focusFlexL7 ? w * 0.047 : h * 0.06), y: p.y))
        }
    }

    private func displayColor(_ s: FixtureState, _ fx: FixturePatch) -> Color {
        if fx.kind == .focusHybrid {
            return Theme.color((s.hybridColor ?? HybridColor.nearest(to: s.color)).rgb)
        }
        return Theme.color(s.color)
    }
}

/// Music analysis + engine status.
struct MusicPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Panel(title: "Music") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.mode == .off ? "–" : String(format: "%.0f", model.status.bpm))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("BPM").foregroundStyle(.secondary)
                    Spacer()
                    Text(model.status.section.rawValue)
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(sectionColor(model.status.section).opacity(0.8)))
                }
                BeatIndicator(beat: model.music.beat(at: OutputController.monotonicNow()),
                              downbeat: model.music.downbeatOffset)
                    .frame(height: 18)
                Meter(label: "Energy", value: model.status.energy, color: Theme.magenta)
                Meter(label: "Bass", value: model.music.bass, color: Theme.green)
                Meter(label: "Mid", value: model.music.mid, color: .yellow)
                Meter(label: "High", value: model.music.high, color: .cyan)
                if let toNext = model.music.beatsToNextSection, let next = model.music.nextSection, model.mode == .setlist {
                    Text("Next: \(next.rawValue) in \(Int(max(0, toNext))) beats")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 320)

            Panel(title: "Show") {
                row("Mode", model.status.modeName)
                row("Energy tier", model.status.tierName)
                row("Palette", model.status.paletteName)
                row("Bar", "\(model.status.bar)  beat \(model.status.beatInBar + 1)")
                Text(model.status.lookSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.status.strobing {
                    Text("STROBE").font(.caption.bold()).foregroundStyle(.yellow)
                }
                if model.blackout {
                    Text("BLACKOUT ACTIVE").font(.caption.bold()).foregroundStyle(.red)
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).fontWeight(.semibold).lineLimit(1)
        }
        .font(.callout)
    }
}

struct Meter: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.4))
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(clamp(value, 0, 1)))
                }
            }
            .frame(height: 7)
        }
    }
}
