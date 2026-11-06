import ELCCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Live input

struct LivePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Panel(title: "Audio input") {
                HStack {
                    Picker("Device", selection: $model.selectedInputID) {
                        ForEach(model.inputDevices) { d in
                            Text("\(d.name) (\(d.channels) ch)").tag(Optional(d.id))
                        }
                    }
                    .labelsHidden()
                    Button {
                        model.refreshInputDevices()
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh device list")
                }
                LevelMeter(level: Double(model.inputLevel))
                    .frame(height: 8)
                Text("Feed the program mix (e.g. from the DJ mixer or FOH desk) into this input. Lights follow the tempo, kicks, energy and build-ups/drops automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Panel(title: "Tempo") {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.1f", model.music.bpm))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("BPM").foregroundStyle(.secondary)
                    Spacer()
                    if model.manualBPM != nil {
                        Text("LOCKED").font(.caption.bold()).padding(4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.magenta.opacity(0.6)))
                    } else {
                        Text("confidence \(Int(model.music.tempoConfidence * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                BeatIndicator(beat: model.music.beat(at: OutputController.monotonicNow()),
                              downbeat: model.music.downbeatOffset)
                    .frame(height: 22)
                HStack {
                    Button("Tap") { model.tapTempo() }
                        .help("Tap at least 4 times to lock the tempo (⌘T)")
                    Button("Auto") { model.setManualBPM(nil) }
                        .disabled(model.manualBPM == nil)
                        .help("Return to automatic tempo detection")
                    Button("½×") { model.setManualBPM((model.manualBPM ?? model.music.bpm) / 2) }
                    Button("2×") { model.setManualBPM((model.manualBPM ?? model.music.bpm) * 2) }
                    Spacer()
                    Button("Set ‘1’") { model.markDownbeat() }
                        .help("Press on the first beat of a bar to align the bar")
                    Button { model.nudge(-0.04) } label: { Image(systemName: "backward.frame") }
                        .help("Nudge beat earlier")
                    Button { model.nudge(0.04) } label: { Image(systemName: "forward.frame") }
                        .help("Nudge beat later")
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Setlist

struct SetlistPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            Panel(title: "Now playing") {
                let track = model.setlist.first { $0.id == model.currentTrackID }
                Text(track?.title ?? "Nothing loaded")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                TrackTimeline(track: track, time: model.playbackTime, duration: model.playbackDuration) { f in
                    model.seek(fraction: f)
                }
                .frame(height: 64)
                HStack {
                    Text(formatTime(model.playbackTime)).monospacedDigit()
                    Spacer()
                    if let a = track?.analysis {
                        Text(String(format: "%.1f BPM", a.bpm)).foregroundStyle(.secondary)
                        Text("· \(a.dropTimes.count) drop\(a.dropTimes.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("-" + formatTime(max(0, model.playbackDuration - model.playbackTime))).monospacedDigit()
                }
                .font(.caption)
                HStack(spacing: 14) {
                    Spacer()
                    Button { model.previous() } label: { Image(systemName: "backward.end.fill") }
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.green)
                    }
                    .buttonStyle(.plain)
                    Button { model.stopPlayback() } label: { Image(systemName: "stop.fill") }
                    Button { model.next() } label: { Image(systemName: "forward.end.fill") }
                    Spacer()
                }
                Toggle("Auto-advance to next track", isOn: $model.autoAdvance)
                    .font(.caption)
            }

            Panel(title: "Setlist", trailing: AnyView(HStack(spacing: 8) {
                Button { model.openAddDialog() } label: { Image(systemName: "plus") }.help("Add .wav / .mp3 files")
                Button { model.loadSetlist() } label: { Image(systemName: "folder") }.help("Open setlist")
                Button { model.saveSetlist() } label: { Image(systemName: "square.and.arrow.down") }.help("Save setlist")
            }.buttonStyle(.borderless))) {
                if model.setlist.isEmpty {
                    Text("Drag .wav or .mp3 files here, or press +. Each track is analysed once (tempo, beat grid, build-ups and drops) so the show can anticipate what is coming.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .multilineTextAlignment(.center)
                } else {
                    List {
                        ForEach(Array(model.setlist.enumerated()), id: \.element.id) { idx, t in
                            SetlistRow(index: idx + 1, track: t,
                                       isCurrent: t.id == model.currentTrackID,
                                       progress: model.analyzing[t.id])
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { model.play(trackID: t.id) }
                                .contextMenu {
                                    Button("Play") { model.play(trackID: t.id) }
                                    Button("Re-analyse") {
                                        if let i = model.setlist.firstIndex(where: { $0.id == t.id }) {
                                            model.setlist[i].analysis = nil
                                        }
                                        model.analyze(trackID: t.id)
                                    }
                                    Button("Remove") {
                                        if let i = model.setlist.firstIndex(where: { $0.id == t.id }) {
                                            model.removeTracks(at: IndexSet(integer: i))
                                        }
                                    }
                                }
                        }
                        .onMove { model.moveTracks(from: $0, to: $1) }
                        .onDelete { model.removeTracks(at: $0) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.green, lineWidth: dropTargeted ? 2 : 0))
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.addTracks(urls: [url]) } }
                    }
                }
                return true
            }
        }
    }
}

struct SetlistRow: View {
    let index: Int
    let track: SetlistTrack
    let isCurrent: Bool
    let progress: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)").font(.caption).foregroundStyle(.secondary).frame(width: 20)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1).fontWeight(isCurrent ? .bold : .regular)
                if let p = progress {
                    ProgressView(value: p).controlSize(.small)
                } else if let a = track.analysis {
                    SectionStrip(analysis: a).frame(height: 5)
                } else {
                    Text("Not analysed").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let a = track.analysis {
                Text(String(format: "%.0f", a.bpm)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(formatTime(track.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

func sectionColor(_ s: MusicSection) -> Color {
    switch s {
    case .silence: return .gray
    case .ambient: return Color(white: 0.4)
    case .breakdown: return .blue
    case .build: return .orange
    case .drop: return Theme.magenta
    case .groove: return Theme.green.opacity(0.7)
    case .peak: return Theme.purple
    }
}

struct SectionStrip: View {
    let analysis: TrackAnalysis
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(Array(analysis.sections.enumerated()), id: \.offset) { _, s in
                    let start = s.startTime / max(analysis.duration, 1)
                    let endTime = s.endBeat < analysis.beatTimes.count ? analysis.beatTimes[s.endBeat] : analysis.duration
                    let w = (endTime - s.startTime) / max(analysis.duration, 1)
                    Rectangle()
                        .fill(sectionColor(s.kind))
                        .frame(width: max(1, geo.size.width * w))
                        .offset(x: geo.size.width * start)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

struct TrackTimeline: View {
    let track: SetlistTrack?
    let time: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                if let a = track?.analysis {
                    SectionStrip(analysis: a)
                        .frame(height: 6)
                        .offset(y: h - 6)
                    Canvas { ctx, size in
                        let n = a.overview.count
                        guard n > 0 else { return }
                        let mid = (size.height - 8) / 2
                        var path = Path()
                        for (i, v) in a.overview.enumerated() {
                            let x = size.width * CGFloat(i) / CGFloat(n)
                            let amp = CGFloat(v) * mid
                            path.move(to: CGPoint(x: x, y: mid - amp))
                            path.addLine(to: CGPoint(x: x, y: mid + amp))
                        }
                        ctx.stroke(path, with: .color(Color.white.opacity(0.45)), lineWidth: 1)
                        for d in a.dropTimes {
                            let x = size.width * d / max(a.duration, 1)
                            ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height - 8)), with: .color(Theme.magenta))
                        }
                    }
                } else if track != nil {
                    Text("Analysing…").font(.caption).foregroundStyle(.secondary).padding(6)
                }
                if duration > 0 {
                    Rectangle()
                        .fill(Theme.green)
                        .frame(width: 2, height: h)
                        .offset(x: w * CGFloat(time / duration))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                onSeek(clamp(Double(v.location.x / max(w, 1)), 0, 1))
            })
        }
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite else { return "0:00" }
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Mood shows

struct MoodPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(title: "Mood shows") {
            Text("Self-running looping looks, no audio needed. From slow to fast:")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(MoodShow.all) { mood in
                    MoodButton(mood: mood, active: model.mode == .mood(mood.id)) {
                        model.setMode(.mood(mood.id))
                    }
                }
            }
            if !model.show.strobeEnabled {
                Text("Strobe is disabled in Settings, so Party Peak runs without strobe hits.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MoodButton: View {
    let mood: MoodShow
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(mood.name).font(.system(size: 14, weight: .bold))
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(i <= mood.speed ? Theme.green : Color.white.opacity(0.15))
                                .frame(width: 4, height: CGFloat(4 + i * 2))
                        }
                    }
                }
                Text(mood.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 3) {
                    ForEach(Array(mood.palettes.prefix(4).enumerated()), id: \.offset) { _, p in
                        Circle().fill(Theme.color(p.a)).frame(width: 9, height: 9)
                        Circle().fill(Theme.color(p.b)).frame(width: 9, height: 9)
                    }
                    Spacer()
                    Text("\(Int(mood.bpm)) BPM").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9).fill(active ? Theme.magenta.opacity(0.35) : Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? Theme.magenta : Theme.panelBorder, lineWidth: active ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Small widgets

struct LevelMeter: View {
    let level: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.4))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(clamp(level, 0, 1)))
            }
        }
    }
}

struct BeatIndicator: View {
    let beat: Double
    let downbeat: Int

    var body: some View {
        let inBar = fmodPositive(beat - Double(downbeat), 4)
        let current = Int(floor(inBar))
        let phase = inBar - floor(inBar)
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(i == current ? (i == 0 ? Theme.magenta : Theme.green).opacity(1 - phase * 0.7) : Color.white.opacity(0.1))
                    .overlay(Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(.white.opacity(0.7)))
            }
        }
    }
}
