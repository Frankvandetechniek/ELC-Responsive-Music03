import ELCCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    VStack(spacing: 12) {
                        ModePicker()
                        switch model.mode {
                        case .off:
                            OffPanel()
                        case .live:
                            LivePanel()
                        case .setlist:
                            SetlistPanel()
                        case .mood:
                            MoodPanel()
                        }
                    }
                    .padding(12)
                }
                .frame(width: 430)

                VStack(spacing: 12) {
                    StageView()
                        .frame(minHeight: 380)
                    MusicPanel()
                }
                .padding([.top, .trailing, .bottom], 12)
            }
        }
        .background(Theme.background)
        .alert("ELC Responsive", isPresented: Binding(get: { model.errorMessage != nil },
                                                       set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(Theme.green).frame(width: 12, height: 12)
                Circle().fill(Theme.magenta).frame(width: 12, height: 12)
                Text("ELC Responsive").font(.system(size: 17, weight: .heavy))
            }
            OutputBadge()
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                Slider(value: $model.show.masterDimmer, in: 0...1)
                    .frame(width: 140)
                Text("\(Int(model.show.masterDimmer * 100))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            .help("Master dimmer")
            Button {
                model.nextLook()
            } label: {
                Label("Next look", systemImage: "forward.fill")
            }
            .help("Change the look now (⌘L)")
            Toggle(isOn: $model.holdLook) {
                Label("Hold", systemImage: "pause.circle")
            }
            .toggleStyle(.button)
            .help("Keep the current look (⇧⌘H)")
            MomentaryButton(title: "FLASH", color: .white) { model.setFlash($0) }
            MomentaryButton(title: "STROBE", color: .yellow) { model.setStrobe($0) }
                .opacity(model.show.strobeEnabled ? 1 : 0.4)
            Button {
                model.blackout.toggle()
            } label: {
                Text(model.blackout ? "BLACKOUT ON" : "BLACKOUT")
                    .font(.system(size: 12, weight: .heavy))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.blackout ? Color.red : Color.red.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .help("Blackout (⌘B)")
            Button {
                openWindow(id: "dmx-monitor")
            } label: {
                Image(systemName: "tablecells")
            }
            .help("DMX monitor")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }
}

struct OutputBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let ok = model.output.enabled && model.outputError == nil
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Theme.green : (model.output.enabled ? Color.red : Color.gray))
                .frame(width: 8, height: 8)
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.3)))
        .help(model.outputError ?? "sACN packets sent: \(model.packetsSent)")
    }

    private var description: String {
        if !model.output.enabled { return "sACN output disabled" }
        if let e = model.outputError { return "sACN error: \(e)" }
        let universes = model.rig.universes.map(String.init).joined(separator: ",")
        let dest = model.output.mode == .unicast ? model.output.nodeIP : "multicast"
        return "sACN U\(universes) → \(dest)"
    }
}

struct ModePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            modeButton("Off", icon: "power", mode: .off, active: model.mode == .off)
            modeButton("Live input", icon: "waveform", mode: .live, active: model.mode == .live)
            modeButton("Setlist", icon: "music.note.list", mode: .setlist, active: model.mode == .setlist)
            modeButton("Mood shows", icon: "sparkles", mode: .mood(model.lastMoodID), active: isMood)
        }
    }

    private var isMood: Bool { if case .mood = model.mode { return true } else { return false } }

    private func modeButton(_ title: String, icon: String, mode: AppMode, active: Bool) -> some View {
        Button {
            model.setMode(mode)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.green.opacity(0.85) : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Theme.green : Theme.panelBorder))
            .foregroundStyle(active ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct OffPanel: View {
    var body: some View {
        Panel(title: "Output off") {
            Text("All fixtures are dark. Choose **Live input** to follow the audio coming into this Mac, **Setlist** to play and light .wav/.mp3 files, or **Mood shows** for self-running looks.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension AppModel {
    var lastMoodID: String {
        if case .mood(let id) = mode { return id }
        return MoodShow.all[1].id
    }
}
