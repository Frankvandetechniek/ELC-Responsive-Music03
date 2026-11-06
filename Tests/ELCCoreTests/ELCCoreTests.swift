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
        XCTAssertEqual(rig.fixtures.map { $0.address }, [1, 17, 33, 49, 65, 81, 97, 116, 135, 154, 173, 192])
        XCTAssertTrue(rig.validate().isEmpty, "\(rig.validate())")
        XCTAssertEqual(rig.l7s.count, 6)
        XCTAssertEqual(rig.hybrids.count, 6)
    }

    func testL7Encoding() {
        var s = FixtureState()
        s.intensity = 1
        s.color = RGB(1, 0, 0)
        s.zoom = 1
        s.pan = 0; s.tilt = 0
        let fx = Rig.elcDefault().fixtures[0]
        let ch = FixtureEncoder.encode(s, patch: fx)
        XCTAssertEqual(ch.count, 16)
        XCTAssertEqual(ch[0], 128)          // pan 270/540
        XCTAssertEqual(ch[1], 128)          // tilt 135/270 = straight up
        XCTAssertEqual(ch[2], 255)          // red
        XCTAssertEqual(ch[3], 0)
        XCTAssertEqual(ch[8], 48)           // shutter open
        XCTAssertEqual(ch[9], 255)          // dimmer
        XCTAssertEqual(ch[10], 0)           // zoom wide
        s.shutter = .strobe(1)
        XCTAssertEqual(FixtureEncoder.encode(s, patch: fx)[8], 95)
    }

    func testHybridEncoding() {
        var s = FixtureState()
        s.intensity = 0.5
        s.hybridColor = .magenta
        s.gobo = 2
        s.goboRotation = 1
        s.prism = 1
        s.prismRotation = 0
        s.zoom = 0
        let fx = Rig.elcDefault().fixtures[6]
        let ch = FixtureEncoder.encode(s, patch: fx)
        XCTAssertEqual(ch.count, 19)
        XCTAssertEqual(ch[2], 41)           // magenta slot
        XCTAssertEqual(ch[3], 19)           // gobo 2 (15-23)
        XCTAssertEqual(ch[4], 128)          // CW fastest
        XCTAssertEqual(ch[6], 48)           // shutter open
        XCTAssertEqual(ch[7], 128)          // dimmer 50%
        XCTAssertEqual(ch[8], 128)          // prism 1 in
        XCTAssertEqual(ch[15], 0)           // zoom narrow
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
        XCTAssertEqual(u[9], 255)                 // L7 1 dimmer = ch 10
        XCTAssertEqual(u[81 - 1 + 9], 255)        // L7 6 dimmer = ch 90
        XCTAssertEqual(u[97 - 1 + 7], 255)        // Hybrid 1 dimmer = ch 104
        XCTAssertEqual(u[192 - 1 + 7], 255)       // Hybrid 6 dimmer = ch 199
        XCTAssertEqual(u[210], 0)                 // nothing patched after 210
    }

    func testWallSafety() {
        let c = FixtureCalibration(backLimitDeg: 0, forwardLimitDeg: 80)
        // Tilting back is clamped to vertical.
        XCTAssertEqual(BeamGeometry.safeAim(pan: 0, tilt: -40, calibration: c).tilt, 0, accuracy: 1e-9)
        // Panned round past 90 degrees and tilted forward = pointing at the wall: must be reduced.
        let a = BeamGeometry.safeAim(pan: 110, tilt: 40, calibration: c)
        let forward = sin(degToRad(a.tilt)) * cos(degToRad(a.pan))
        XCTAssertGreaterThanOrEqual(forward, -1e-9)
        // Forward limit
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

