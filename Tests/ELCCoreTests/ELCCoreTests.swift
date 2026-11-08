import XCTest
@testable import ELCCore

/// Synthesises a simple dance track: kick on every beat, hats on the off-beats,
/// optional breakdown (no kick, quiet pad) between `breakdown` seconds.
func synthTrack(bpm: Double, seconds: Double, sr: Double = 44100, breakdown: ClosedRange<Double>? = nil) -> [Float] {
    let n = Int(seconds * sr)
    var out = [Float](repeating: 0, count: n)
    let period = 60 / bpm
    var noise = SeededRandom(seed: 42)
    for i in 0..<n {
        let t = Double(i) / sr
        let inBreak = breakdown?.contains(t) ?? false
        let beatPhase = fmodPositive(t, period)
        var v = 0.0
        if !inBreak {
            // kick: decaying pitch-swept sine
            let env = exp(-beatPhase * 18)
            v += 0.8 * env * sin(2 * .pi * (50 + 80 * exp(-beatPhase * 30)) * beatPhase)
            // hats on the off-beat
            let off = fmodPositive(t - period / 2, period)
            v += 0.15 * exp(-off * 60) * (noise.unit() * 2 - 1)
            // bass line
            v += 0.2 * sin(2 * .pi * 55 * t) * (beatPhase > period * 0.3 ? 1 : 0.2)
        }
        // pad (always present, quieter in breakdown)
        v += (inBreak ? 0.05 : 0.08) * sin(2 * .pi * 440 * t) * (0.6 + 0.4 * sin(2 * .pi * 0.25 * t))
        out[i] = Float(v)
    }
    return out
}

final class SACNTests: XCTestCase {
    func testPacketLayout() {
        let cid = [UInt8](repeating: 0xAB, count: 16)
        let b = SACNPacketBuilder(cid: cid, sourceName: "ELC Responsive", priority: 100)
        var slots = [UInt8](repeating: 0, count: 512)
        slots[0] = 11; slots[511] = 99
        let p = b.packet(universe: 7, sequence: 5, slots: slots)
        XCTAssertEqual(p.count, 638)
        XCTAssertEqual(Array(p[4..<13]), Array("ASC-E1.17".utf8))
        XCTAssertEqual(p[16], 0x72); XCTAssertEqual(p[17], 0x6E)       // 0x7000 | 622
        XCTAssertEqual(Array(p[18..<22]), [0, 0, 0, 4])
        XCTAssertEqual(Array(p[22..<38]), cid)
        XCTAssertEqual(p[38], 0x72); XCTAssertEqual(p[39], 0x58)       // 0x7000 | 600
        XCTAssertEqual(Array(p[40..<44]), [0, 0, 0, 2])
        XCTAssertEqual(Array(p[44..<58]), Array("ELC Responsive".utf8))
        XCTAssertEqual(p[108], 100)
        XCTAssertEqual(p[111], 5)
        XCTAssertEqual(p[113], 0); XCTAssertEqual(p[114], 7)
        XCTAssertEqual(p[115], 0x72); XCTAssertEqual(p[116], 0x0B)     // 0x7000 | 523
        XCTAssertEqual(p[117], 0x02); XCTAssertEqual(p[118], 0xA1)
        XCTAssertEqual(p[123], 0x02); XCTAssertEqual(p[124], 0x01)     // 513
        XCTAssertEqual(p[125], 0)
        XCTAssertEqual(p[126], 11); XCTAssertEqual(p[637], 99)
        XCTAssertEqual(SACNPacketBuilder.multicastAddress(for: 1), "239.255.0.1")
        XCTAssertEqual(SACNPacketBuilder.multicastAddress(for: 300), "239.255.1.44")
    }

    func testSenderSendsToLocalhost() {
        let s = SACNSender(cid: SACNPacketBuilder.randomCID(), sourceName: "test", priority: 100)
        s.open(localInterfaceIP: nil)
        XCTAssertTrue(s.send(universe: 1, slots: [UInt8](repeating: 1, count: 512), mode: .unicast, destination: "127.0.0.1"))
        XCTAssertFalse(s.send(universe: 1, slots: [], mode: .unicast, destination: "not-an-ip"))
        s.close()
    }
}

final class FixtureTests: XCTestCase {
    func testDefaultPatch() {
        let rig = Rig.elcDefault()
        XCTAssertEqual(rig.fixtures.map { $0.address }, [1, 51, 101, 151, 201, 251, 301, 326, 351, 376, 401, 426])
        XCTAssertEqual(rig.l7s.map { $0.kind.channelCount }, [50, 50, 50, 50, 50, 50])
        XCTAssertEqual(rig.hybrids.map { $0.kind.channelCount }, [25, 25, 25, 25, 25, 25])
        XCTAssertTrue(rig.validate().isEmpty, "\(rig.validate())")
        XCTAssertEqual(rig.l7s.count, 6)
        XCTAssertEqual(rig.hybrids.count, 6)
    }

    func testOldSavedFixtureKindsStillDecode() throws {
        let old = #"["ADJ Focus Flex L7 (16ch Basic)", "ADJ Focus Hybrid (19ch)"]"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode([FixtureKind].self, from: old), [.focusFlexL7, .focusHybrid])
    }

    /// ADJ Focus Flex L7 — DMX Traits, "Ext 7" (50 channel) column.
    func testL7Extended7Encoding() {
        var s = FixtureState()
        s.intensity = 1
        s.color = RGB(1, 0, 0)
        s.pixels = [RGB(1, 0, 0), RGB(0, 1, 0), RGB(0, 0, 1), RGB(0, 0, 0), RGB(1, 1, 1), RGB(0.5, 0, 0), RGB(0, 0, 1)]
        s.zoom = 1
        s.pan = 0; s.tilt = 0
        let fx = Rig.elcDefault().fixtures[0]
        let ch = FixtureEncoder.encode(s, patch: fx)
        XCTAssertEqual(ch.count, 50)
        // 1/2 pan + fine, 3/4 tilt + fine: home = centre of 540° / 270° (32768)
        XCTAssertEqual(Int(ch[0]) << 8 | Int(ch[1]), 32768)
        XCTAssertEqual(Int(ch[2]) << 8 | Int(ch[3]), 32768)
        // 5-8 pixel 1 RGBL, 9-12 pixel 2, ..., 29-32 pixel 7
        XCTAssertEqual(Array(ch[4..<8]), [255, 0, 0, 0])
        XCTAssertEqual(Array(ch[8..<12]).prefix(3), [0, 255, 0])
        XCTAssertEqual(Array(ch[12..<15]), [0, 0, 255])
        XCTAssertEqual(Array(ch[16..<20]), [0, 0, 0, 0])          // pixel 4 (ch 17-20) off
        XCTAssertEqual(Array(ch[20..<23]), [255, 255, 255])       // pixel 5 (ch 21-24) white
        XCTAssertEqual(ch[24], 128)                 // pixel 6 (ch 25) red 50 %
        XCTAssertEqual(Array(ch[28..<32]), [0, 0, 255, 0])
        XCTAssertEqual(Array(ch[32..<38]), [0, 0, 0, 0, 0, 0])   // 33-38 CT / virtual wheels / macros off
        XCTAssertEqual(ch[38], 48)                  // 39 shutter open
        XCTAssertEqual(ch[39], 255); XCTAssertEqual(ch[40], 255) // 40/41 dimmer 16 bit
        XCTAssertEqual(ch[41], 0); XCTAssertEqual(ch[42], 0)     // 42/43 zoom wide
        XCTAssertEqual(ch[44], 30)                  // 45 dim curve linear
        XCTAssertEqual(ch[45], 0)                   // 46 no internal program
        XCTAssertEqual(ch[49], 0)                   // 50 no special function
        s.shutter = .strobe(1)
        XCTAssertEqual(FixtureEncoder.encode(s, patch: fx)[38], 95)
        // Without per-pixel data all 7 pixels take the fixture colour.
        s.pixels = nil
        let solid = FixtureEncoder.encode(s, patch: fx)
        for p in 0..<7 { XCTAssertEqual(solid[4 + p * 4], 255); XCTAssertEqual(solid[5 + p * 4], 0) }
    }

    /// ADJ Focus Hybrid — DMX Traits, 25 channel column.
    func testHybrid25Encoding() {
        var s = FixtureState()
        s.intensity = 0.5
        s.hybridColor = .magenta
        s.gobo = 2
        s.goboRotation = 1
        s.prism = 1
        s.prismRotation = 0
        s.zoom = 0
        s.frost = 1
        s.tilt = 10
        let fx = Rig.elcDefault().fixtures[6]
        let ch = FixtureEncoder.encode(s, patch: fx)
        XCTAssertEqual(ch.count, 25)
        XCTAssertEqual(Int(ch[0]) << 8 | Int(ch[1]), 32768)       // 1/2 pan
        XCTAssertGreaterThan(Int(ch[2]) << 8 | Int(ch[3]), 32768) // 3/4 tilt (forward)
        XCTAssertEqual(ch[4], 41)           // 5 colour wheel: magenta
        XCTAssertEqual(ch[5], 19)           // 6 gobo 2 (15-23)
        XCTAssertEqual(ch[6], 128)          // 7 gobo rotation CW fastest
        XCTAssertEqual(ch[7], 0)            // 8 static gobo open
        XCTAssertEqual(ch[8], 48)           // 9 shutter open
        XCTAssertEqual(Int(ch[9]) << 8 | Int(ch[10]), 32768) // 10/11 dimmer 50 %
        XCTAssertEqual(ch[11], 128)         // 12 prism 1 in
        XCTAssertEqual(ch[14], 0)           // 15 prism 2 out
        XCTAssertEqual(ch[17], 128)         // 18 focus default 50 %
        XCTAssertEqual(ch[18], 0); XCTAssertEqual(ch[19], 0) // 19/20 zoom narrow
        XCTAssertEqual(ch[20], 255)         // 21 frost
        XCTAssertEqual(ch[22], 30)          // 23 dim curve linear
        XCTAssertEqual(ch[24], 0)           // 25 special: none
        XCTAssertEqual(HybridColor.nearest(to: .brandGreen), .green)
        XCTAssertEqual(HybridColor.nearest(to: .brandMagenta), .magenta)
        XCTAssertEqual(HybridColor.nearest(to: .brandPurple), .purple)
        XCTAssertEqual(HybridColor.nearest(to: .white), .open)
    }

    func testFramesPlaceFixturesAtTheirAddress() {
        let rig = Rig.elcDefault()
        var states: [Int: FixtureState] = [:]
        for fx in rig.fixtures { var s = FixtureState(); s.intensity = 1; states[fx.id] = s }
        let frames = FixtureEncoder.frames(rig: rig, states: states)
        let u = frames[1]!
        XCTAssertEqual(u[1 - 1 + 39], 255)        // L7 1 dimmer = ch 40
        XCTAssertEqual(u[251 - 1 + 39], 255)      // L7 6 dimmer = ch 290
        XCTAssertEqual(u[301 - 1 + 9], 255)       // Hybrid 1 dimmer = ch 310
        XCTAssertEqual(u[426 - 1 + 9], 255)       // Hybrid 6 dimmer = ch 435
        XCTAssertEqual(u[450], 0)                 // nothing patched after 450
    }

    func testSixteenBitMovementIsSmooth() {
        let c = FixtureCalibration()
        // 0.1° steps that 8 bit (≈2.1°/step) could not show are visible in 16 bit.
        let a = BeamGeometry.dmx16(pan: 10.0, tilt: 20, calibration: c).pan
        let b = BeamGeometry.dmx16(pan: 10.1, tilt: 20, calibration: c).pan
        XCTAssertGreaterThan(b, a)
    }

    func testWallSafety() {
        let c = FixtureCalibration(backLimitDeg: 0, forwardLimitDeg: 80)
        XCTAssertEqual(BeamGeometry.safeAim(pan: 0, tilt: -40, calibration: c).tilt, 0, accuracy: 1e-9)
        let a = BeamGeometry.safeAim(pan: 110, tilt: 40, calibration: c)
        let forward = sin(degToRad(a.tilt)) * cos(degToRad(a.pan))
        XCTAssertGreaterThanOrEqual(forward, -1e-9)
        XCTAssertEqual(BeamGeometry.safeAim(pan: 0, tilt: 120, calibration: c).tilt, 80)
    }
}

final class AnalysisTests: XCTestCase {
    func testTempoEstimateOnSynthTrack() {
        let sr = 44100.0
        let audio = synthTrack(bpm: 128, seconds: 20, sr: sr)
        let ex = FeatureExtractor(sampleRate: sr)
        var onsets: [Double] = []
        ex.process(audio) { onsets.append($0.onset) }
        let est = TempoEstimator.estimate(onsets: onsets, fps: ex.framesPerSecond)
        XCTAssertNotNil(est)
        XCTAssertEqual(est!.bpm, 128, accuracy: 1.5)
    }

    func testLiveAnalyzerLocksTempo() {
        let sr = 48000.0
        let audio = synthTrack(bpm: 124, seconds: 16, sr: sr)
        let la = LiveAnalyzer(sampleRate: sr)
        var t = 0.0
        var i = 0
        while i < audio.count {
            let n = min(1024, audio.count - i)
            t += Double(n) / sr
            la.process(Array(audio[i..<(i + n)]), now: t)
            i += n
        }
        let s = la.state
        XCTAssertEqual(s.bpm, 124, accuracy: 2)
        XCTAssertFalse(s.isSilent)
        XCTAssertGreaterThan(s.kickCount, 20)
        // Beat phase should be locked to the kicks (kick at integer beats, allow latency compensation shift).
        let phase = fmodPositive(s.beat(at: t) - la.config.latencyCompensation * s.bpm / 60, 1)
        let expected = fmodPositive(t / (60 / 124.0), 1)
        var diff = abs(phase - expected); if diff > 0.5 { diff = 1 - diff }
        XCTAssertLessThan(diff, 0.2, "phase \(phase) expected \(expected)")
    }

    func testTrackAnalysisFindsDrop() {
        let sr = 22050.0
        let bpm = 126.0
        let beat = 60 / bpm
        // 32 beats groove, 32 beats breakdown, 48 beats drop
        let audio = synthTrack(bpm: bpm, seconds: beat * 112, sr: sr, breakdown: (beat * 32)...(beat * 64))
        let a = TrackAnalyzer.analyze(samples: audio, sampleRate: sr)
        XCTAssertEqual(a.bpm, bpm, accuracy: 1.5)
        XCTAssertGreaterThan(a.beatTimes.count, 100)
        let kinds = a.sections.map { $0.kind }
        XCTAssertTrue(kinds.contains(.drop), "sections: \(a.sections.map { "\($0.kind.rawValue)@\($0.startTime)" })")
        if let drop = a.sections.first(where: { $0.kind == .drop }) {
            XCTAssertEqual(drop.startTime, beat * 64, accuracy: beat * 4.5)
        }
        // Playback source reports the upcoming drop during the breakdown.
        let src = TrackMusicSource(analysis: a)
        let st = src.state(atPlaybackTime: beat * 60, now: 0, lookahead: 0, isPlaying: true)
        XCTAssertEqual(st.nextSection, .drop)
        XCTAssertNotNil(st.beatsToNextSection)
    }
}

