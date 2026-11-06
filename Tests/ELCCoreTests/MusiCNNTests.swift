import XCTest
@testable import ELCCore

/// Compares the Swift MusiCNN port with reference outputs computed in Python
/// (librosa mel spectrogram + TensorFlow conv ops with the same exported weights).
final class MusiCNNTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/musicnn")

    func load(_ name: String) throws -> [Float] {
        let d = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testMelFilterbankMatchesLibrosa() throws {
        let ref = try load("melfb_96x257.f32")
        let fb = MusiCNNFrontend().filterbank
        var maxErr: Float = 0
        for m in 0..<96 { for k in 0..<257 { maxErr = max(maxErr, abs(fb[m][k] - ref[m * 257 + k])) } }
        XCTAssertLessThan(maxErr, 1e-6)
    }

    func testLogMelMatchesLibrosa() throws {
        let sig = try load("signal_16k.f32")
        let ref = try load("logmel_187x96.f32")
        let (mel, frames) = MusiCNNFrontend().logMel(sig)
        XCTAssertEqual(frames, 251)
        var maxErr: Float = 0
        for i in 0..<ref.count { maxErr = max(maxErr, abs(mel[i] - ref[i])) }
        XCTAssertLessThan(maxErr, 2e-3, "log-mel differs from librosa by \(maxErr)")
    }

    func testNetworkMatchesTensorFlowReference() throws {
        let model = try MusiCNN(directory: Self.repoRoot.appendingPathComponent("Resources/Models"))
        XCTAssertEqual(model.labels.count, 50)
        let logmel = try load("logmel_187x96.f32")
        let ref = try load("probs_50.f32")
        let probs = model.predict(logMel: logmel, frames: 187)
        var maxErr: Float = 0
        for i in 0..<50 { maxErr = max(maxErr, abs(probs[i] - ref[i])) }
        XCTAssertLessThan(maxErr, 1e-3, "tag probabilities differ from reference by \(maxErr)")
        let top = probs.indices.max { probs[$0] < probs[$1] }!
        XCTAssertEqual(model.labels[top], "electronic")
    }
}

final class VibeTagMappingTests: XCTestCase {
    /// DSP features of a typical modern pop production that fooled the old rules:
    /// heavy bass, bright, big dynamics, steady kick.
    func popLikeFeatures() -> VibeFeatures {
        var f = VibeFeatures()
        f.bpm = 118; f.pulseClarity = 0.7; f.onsetRate = 4.5; f.fourOnFloor = 0.6; f.backbeat = 0.6
        f.syncopation = 0.3; f.brightness = 0.55; f.bassShare = 0.55; f.dynamics = 0.6; f.percussiveness = 0.7
        f.majorness = 0.3; f.tonalClarity = 0.6
        return f
    }

    func testPopTagsWinOverRhythmRules() {
        var f = popLikeFeatures()
        // MusiCNN output shape for a pop hit
        f.tags = ["pop": 0.55, "female vocalists": 0.35, "catchy": 0.2, "dance": 0.2, "electronic": 0.15, "happy": 0.12, "Hip-Hop": 0.05, "rnb": 0.08]
        let v = VibeModel.infer(f)
        XCTAssertEqual(v.style, .pop, "\(v.scores)")
        XCTAssertTrue(v.usesNeuralModel)
        XCTAssertGreaterThan(v.valence, 0.5)
        XCTAssertFalse(v.topTags.isEmpty)
    }

    func testSingerSongwriterIsNotEDM() {
        var f = popLikeFeatures()
        f.tags = ["pop": 0.35, "acoustic": 0.3, "female vocalists": 0.3, "singer-songwriter": 0.0, "folk": 0.15, "Mellow": 0.2, "beautiful": 0.15]
        let v = VibeModel.infer(f)
        XCTAssertTrue([.pop, .ballad].contains(v.style), "got \(v.style)")
        XCTAssertLessThan(v.arousal, 0.6)
    }

    func testHipHopAndHouseTags() {
        var f = popLikeFeatures()
        f.tags = ["Hip-Hop": 0.6, "rnb": 0.3, "sexy": 0.1]
        XCTAssertEqual(VibeModel.infer(f).style, .hipHop)
        f.tags = ["House": 0.5, "electronic": 0.5, "dance": 0.4]
        f.fourOnFloor = 0.9; f.bpm = 124
        XCTAssertEqual(VibeModel.infer(f).style, .house)
        f.tags = ["rock": 0.6, "alternative rock": 0.3, "guitar": 0.3]
        XCTAssertEqual(VibeModel.infer(f).style, .rock)
    }
}
