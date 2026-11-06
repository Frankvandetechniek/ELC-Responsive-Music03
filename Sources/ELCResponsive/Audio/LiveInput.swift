import AVFoundation
import CoreAudio
import ELCCore

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let channels: Int
}

/// Captures the selected audio input and feeds it to a `LiveAnalyzer`.
final class LiveInput {
    private var engine: AVAudioEngine?
    private let analyzerBox = Locked<LiveAnalyzer?>(nil)
    let level = Locked<Float>(0)
    private var mono: [Float] = []
    private let classifier = LiveSoundClassifier()
    private let genreTagger = LiveGenreTagger()

    var analyzer: LiveAnalyzer? { analyzerBox.get() }
    var isRunning: Bool { engine?.isRunning ?? false }

    func start(deviceID: AudioDeviceID?, configure: (LiveAnalyzer) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let dev = deviceID, let au = input.audioUnit {
            var d = dev
            let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                throw NSError(domain: "ELCResponsive", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Could not select audio input (\(status))"])
            }
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "ELCResponsive", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "The selected input has no channels. Check microphone permission and the device."])
        }
        let analyzer = LiveAnalyzer(sampleRate: format.sampleRate)
        configure(analyzer)
        analyzerBox.set(analyzer)
        classifier.onEvidence = { [weak analyzer] ev in analyzer?.updateSoundEvidence(ev) }
        classifier.start(sampleRate: format.sampleRate)
        genreTagger.onTags = { [weak analyzer] tags in analyzer?.updateTags(tags) }
        genreTagger.start(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        classifier.stop()
        genreTagger.stop()
        analyzerBox.set(nil)
        level.set(0)
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chans = Int(buffer.format.channelCount)
        if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
        var peak: Float = 0
        let scale = 1 / Float(max(chans, 1))
        for i in 0..<frames {
            var v: Float = 0
            for c in 0..<chans { v += data[c][i] }
            v *= scale
            mono[i] = v
            peak = max(peak, abs(v))
        }
        level.set(max(peak, level.get() * 0.8))
        analyzerBox.get()?.process(mono, now: ProcessInfo.processInfo.systemUptime)
        classifier.feed(mono)
        genreTagger.feed(mono)
    }

    // MARK: - Device list

    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let ch = inputChannelCount(id)
            guard ch > 0 else { return nil }
            return AudioInputDevice(id: id, name: deviceName(id) ?? "Device \(id)", channels: ch)
        }
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard st == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
