import ELCCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            OutputSettingsView()
                .tabItem { Label("sACN Output", systemImage: "network") }
            ShowSettingsView()
                .tabItem { Label("Show", systemImage: "sparkles") }
            FixtureSettingsView()
                .tabItem { Label("Fixtures", systemImage: "lightbulb.2") }
            AnalysisSettingsView()
                .tabItem { Label("Audio Analysis", systemImage: "waveform.path.ecg") }
        }
        .frame(width: 760, height: 620)
    }
}

// MARK: - Output

struct OutputSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var mirrorText = ""

    var body: some View {
        Form {
            Section("sACN (E1.31)") {
                Toggle("Send sACN", isOn: $model.output.enabled)
                Picker("Transmission", selection: $model.output.mode) {
                    Text("Unicast to node").tag(SACNSender.Mode.unicast)
                    Text("Multicast").tag(SACNSender.Mode.multicast)
                }
                .pickerStyle(.segmented)
                TextField("NodeGBx8 IP address", text: $model.output.nodeIP)
                    .disabled(model.output.mode == .multicast)
                TextField("Send from local IP (optional)", text: $model.output.localInterfaceIP,
                          prompt: Text("automatic"))
                TextField("Source name", text: $model.output.sourceName)
                Stepper("Priority: \(model.output.priority)", value: $model.output.priority, in: 1...200)
                Stepper("Rig universe: \(rigUniverse.wrappedValue)", value: rigUniverse, in: 1...63999)
                TextField("Mirror to extra universes (comma separated)", text: $mirrorText)
                    .onAppear { mirrorText = model.output.mirrorUniverses.map(String.init).joined(separator: ", ") }
                    .onSubmit { applyMirror() }
                    .help("Sends an identical copy of the rig universe to these universes, e.g. to drive more NodeGBx8 ports with the same show.")
            }
            Section("Status") {
                LabeledContent("Packets sent", value: "\(model.packetsSent)")
                LabeledContent("Last error", value: model.outputError ?? "none")
                LabeledContent("Destination", value: destination)
            }
            Section("Setting up the dmXLAN NodeGBx8") {
                Text("""
                1. Connect the Mac and the NodeGBx8 to the same network (or directly with a cable).
                2. Give the Mac an IP in the same range as the node (factory default nodes are usually in the 2.x.x.x or 10.x.x.x range; check the node's display/web page).
                3. In the node's web interface (or front panel), set the desired DMX port to **sACN input**, universe **\(rigUniverse.wrappedValue)**.
                4. Enter the node's IP above (unicast is the most reliable) — or choose multicast if the node is configured to listen on 239.255.0.\(rigUniverse.wrappedValue).
                5. The fixtures expect: Flex L7 in **16 channel (Basic)** mode, Focus Hybrid in **19 channel** mode.
                """)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var destination: String {
        let u = model.rig.universes
        if model.output.mode == .multicast {
            return u.map { SACNPacketBuilder.multicastAddress(for: $0) }.joined(separator: ", ") + " : 5568"
        }
        return "\(model.output.nodeIP) : 5568"
    }

    private var rigUniverse: Binding<Int> {
        Binding(get: { Int(model.rig.fixtures.first?.universe ?? 1) },
                set: { v in
                    var r = model.rig
                    for i in r.fixtures.indices { r.fixtures[i].universe = UInt16(clamp(v, 1, 63999)) }
                    model.rig = r
                })
    }

    private func applyMirror() {
        model.output.mirrorUniverses = mirrorText
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { UInt16($0) }
            .filter { $0 >= 1 && $0 <= 63999 }
    }
}

// MARK: - Show

struct ShowSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Colours") {
                Picker("Colour policy", selection: $model.show.colorPolicy) {
                    ForEach(ColorPolicy.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Brand palettes: green/magenta, green/purple, magenta/purple, green/white, magenta/white. “Mostly brand” mixes in ocean, sunset, fire, ice and toxic about a quarter of the time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Strobe (photosensitivity)") {
                Toggle("Allow strobe effects", isOn: $model.show.strobeEnabled)
                LabeledSlider(label: "Max strobe speed", value: $model.show.strobeMaxRate, range: 0...1, format: "%.0f%%", scale: 100)
                    .disabled(!model.show.strobeEnabled)
                Text("Strobe is only used on drops, the last beat before a known drop and (EDM only) short peak hits; never in ballads or ambient music. Limited to 4 seconds at a time with a 6 second rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Style") {
                Picker("Lighting style", selection: $model.show.styleOverride) {
                    Text("Auto (detected from the music)").tag(MusicStyle?.none)
                    ForEach(MusicStyle.allCases) { Text($0.rawValue).tag(MusicStyle?.some($0)) }
                }
                Text("Auto uses the on-device vibe model (rhythm, key, tempo + Apple's built-in instrument/vocal classifier). Each style has its own lighting personality: phrase length, fade times, movement speed, accents and strobe use.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Behaviour") {
                LabeledSlider(label: "Movement size", value: $model.show.movementAmount, range: 0...1.5, format: "%.0f%%", scale: 100)
                LabeledSlider(label: "Reactivity (energy bias)", value: $model.show.energyBias, range: -0.3...0.3, format: "%+.0f", scale: 100)
                LabeledSlider(label: "Look length (phrases)", value: $model.show.lookChangeRate, range: 0.5...3, format: "×%.1f", scale: 1)
                LabeledSlider(label: "Static look intensity", value: $model.show.staticLevel, range: 0.1...1, format: "%.0f%%", scale: 100)
                Toggle("Use gobos on the Hybrids", isOn: $model.show.useGobos)
                Toggle("Short blackout right before a drop (setlist)", isOn: $model.show.preDropGap)
            }
            Section("When the music stops") {
                Picker("Idle", selection: $model.show.idleBehaviour) {
                    ForEach(IdleBehaviour.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledSlider(label: "Ambient glow level", value: $model.show.idleLevel, range: 0...0.5, format: "%.0f%%", scale: 100)
                    .disabled(model.show.idleBehaviour != .ambientGlow)
            }
        }
        .formStyle(.grouped)
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let scale: Double

    var body: some View {
        HStack {
            Text(label)
            Slider(value: $value, in: range)
            Text(String(format: format, value * scale))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
        }
    }
}

// MARK: - Fixtures

struct FixtureSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Int? = 1

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(model.rig.fixtures) { fx in
                    HStack {
                        Text(fx.name).fontWeight(.semibold)
                        Spacer()
                        Text("U\(fx.universe).\(fx.address)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(fx.id)
                }
            }
            .frame(minWidth: 210, maxWidth: 240)

            VStack(alignment: .leading) {
                if let id = selection, let idx = model.rig.fixtures.firstIndex(where: { $0.id == id }) {
                    FixtureDetail(index: idx)
                } else {
                    Text("Select a fixture").foregroundStyle(.secondary)
                }
                let problems = model.rig.validate()
                if !problems.isEmpty {
                    ForEach(problems, id: \.self) { Text("⚠︎ " + $0).font(.caption).foregroundStyle(.orange) }
                }
                HStack {
                    Button("Reset to ELC default patch") { model.resetRig() }
                    Spacer()
                    Button(model.testFixtureID == nil ? "Test selected fixture" : "Stop test") {
                        model.startTest(fixtureID: model.testFixtureID == nil ? selection : nil)
                    }
                    .tint(model.testFixtureID == nil ? .accentColor : .red)
                }
                .padding()
            }
            .frame(minWidth: 480)
        }
        .onChange(of: selection) { newValue in
            if model.testFixtureID != nil { model.startTest(fixtureID: newValue) }
        }
        .onDisappear { model.startTest(fixtureID: nil) }
    }
}

struct FixtureDetail: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    var body: some View {
        let fx = $model.rig.fixtures[index]
        Form {
            Section("\(fx.wrappedValue.name) — \(fx.wrappedValue.kind.rawValue)") {
                Stepper("Universe: \(fx.wrappedValue.universe)", value: fx.universe, in: 1...63999)
                Stepper("DMX address: \(fx.wrappedValue.address)", value: fx.address, in: 1...(513 - fx.wrappedValue.kind.channelCount))
                Text("Uses channels \(fx.wrappedValue.address)–\(fx.wrappedValue.address + fx.wrappedValue.kind.channelCount - 1)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Orientation / calibration") {
                Text("Use **Test selected fixture** with the poses below. ‘Straight up’ must point the beam vertically; ‘Forward 45°’ must lean towards the audience (never towards the LED wall). Adjust until correct.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Test pose", selection: $model.testPose) {
                    ForEach(AppModel.TestPose.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(label: "Pan home (faces audience)", value: fx.calibration.panHomeDeg, range: 0...fx.wrappedValue.calibration.panRangeDeg, format: "%.0f°", scale: 1)
                Toggle("Invert pan", isOn: fx.calibration.panInvert)
                LabeledSlider(label: "Tilt for beam straight up", value: fx.calibration.tiltUpDeg, range: 0...fx.wrappedValue.calibration.tiltRangeDeg, format: "%.0f°", scale: 1)
                Toggle("Invert tilt (forward goes to the wall)", isOn: fx.calibration.tiltInvert)
                LabeledSlider(label: "Max lean towards LED wall", value: fx.calibration.backLimitDeg, range: 0...45, format: "%.0f°", scale: 1)
                LabeledSlider(label: "Max lean towards audience", value: fx.calibration.forwardLimitDeg, range: 10...110, format: "%.0f°", scale: 1)
                LabeledSlider(label: "Max pan either side", value: fx.calibration.panLimitDeg, range: 30...170, format: "%.0f°", scale: 1)
                Picker("Pan range (fixture menu)", selection: fx.calibration.panRangeDeg) {
                    Text("540°").tag(540.0)
                    Text("630°").tag(630.0)
                }
                .pickerStyle(.segmented)
                if fx.wrappedValue.kind == .focusHybrid {
                    LabeledSlider(label: "Gobo focus", value: fx.calibration.focus, range: 0...1, format: "%.0f%%", scale: 100)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Analysis

struct AnalysisSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Latency") {
                LabeledSlider(label: "Live input: lights ahead by", value: $model.analysis.latencyCompensation, range: 0...0.25, format: "%.0f ms", scale: 1000)
                LabeledSlider(label: "Setlist: lights ahead by", value: $model.analysis.setlistLookahead, range: 0...0.25, format: "%.0f ms", scale: 1000)
                Text("Compensates for audio-interface, network and fixture delay. Increase if flashes land after the kick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tempo detection (live input)") {
                LabeledSlider(label: "Minimum BPM", value: $model.analysis.minBPM, range: 60...120, format: "%.0f", scale: 1)
                LabeledSlider(label: "Maximum BPM", value: $model.analysis.maxBPM, range: 130...200, format: "%.0f", scale: 1)
                LabeledSlider(label: "Typical BPM", value: $model.analysis.preferredBPM, range: 80...160, format: "%.0f", scale: 1)
                Text("Changes apply when live input is (re)started. Use Tap / ½× / 2× in the Live panel to correct the tempo during a show.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - DMX monitor

struct DMXMonitorView: View {
    @EnvironmentObject var model: AppModel
    @State private var universe: UInt16 = 1

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Universe", selection: $universe) {
                    ForEach(model.frames.keys.sorted(), id: \.self) { Text("Universe \($0)").tag($0) }
                }
                .frame(width: 200)
                Spacer()
                Text("Patched: 1–210").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                let data = model.frames[universe] ?? [UInt8](repeating: 0, count: 512)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 2), count: 16), spacing: 2) {
                    ForEach(0..<512, id: \.self) { i in
                        VStack(spacing: 0) {
                            Text("\(i + 1)").font(.system(size: 7)).foregroundStyle(.secondary)
                            Text("\(data[i])").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        }
                        .frame(width: 38, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ownerColor(channel: i + 1).opacity(0.12 + 0.6 * Double(data[i]) / 255))
                        )
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { universe = model.rig.universes.first ?? 1 }
    }

    private func ownerColor(channel: Int) -> Color {
        for fx in model.rig.fixtures where fx.universe == universe {
            if channel >= fx.address && channel < fx.address + fx.kind.channelCount {
                return fx.kind == .focusFlexL7 ? Theme.green : Theme.magenta
            }
        }
        return Color.gray
    }
}
