import Foundation

public struct OutputSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var mode: SACNSender.Mode = .unicast
    /// IP address of the dmXLAN NodeGBx8 (unicast).
    public var nodeIP: String = "2.0.0.10"
    /// Optional local interface IP to send from (useful with multiple network ports).
    public var localInterfaceIP: String = ""
    public var sourceName: String = "ELC Responsive"
    public var priority: Int = 100
    /// Additional universes that receive an exact copy of the rig's universe(s)
    /// (e.g. to feed several NodeGBx8 outputs with the same data).
    public var mirrorUniverses: [UInt16] = []
    public var frameRate: Double = 44

    public init() {}
}

/// Owns the real-time loop: pulls music state, runs the engine, encodes DMX and sends sACN.
public final class OutputController: @unchecked Sendable {
    public let engine: ShowEngine
    private let sender: SACNSender
    private let queue = DispatchQueue(label: "elc.output", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var settings: OutputSettings
    private var lastTick: Double = 0
    private var keepAliveCounter = 0
    private var lastFrames: [UInt16: [UInt8]] = [:]

    /// Called on the output thread every frame to obtain the current music state.
    public var musicProvider: () -> MusicState = { MusicState() }

    private let snapshot = Locked<(states: [Int: FixtureState], frames: [UInt16: [UInt8]], status: EngineStatus)>(([:], [:], EngineStatus()))
    private let pending = Locked<[(OutputController) -> Void]>([])

    public init(rig: Rig, settings: OutputSettings, cid: [UInt8]) {
        engine = ShowEngine(rig: rig)
        self.settings = settings
        sender = SACNSender(cid: cid, sourceName: settings.sourceName, priority: UInt8(clamp(settings.priority, 1, 200)))
    }

    public static func monotonicNow() -> Double { ProcessInfo.processInfo.systemUptime }

    public func start() {
        queue.async { [self] in
            sender.open(localInterfaceIP: settings.localInterfaceIP)
            let t = DispatchSource.makeTimerSource(queue: queue)
            let interval = 1.0 / clamp(settings.frameRate, 10, 44)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            lastTick = Self.monotonicNow()
            t.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            // Tell receivers the stream is terminated (E1.31 6.2.6).
            if settings.enabled {
                for (u, frame) in lastFrames {
                    for _ in 0..<3 { sender.send(universe: u, slots: frame, mode: settings.mode, destination: settings.nodeIP, terminated: true) }
                }
            }
            sender.close()
        }
    }

    /// Runs a closure on the output thread before the next frame (thread-safe engine access).
    public func perform(_ body: @escaping (OutputController) -> Void) {
        pending.mutate { $0.append(body) }
    }

    public func update(settings new: OutputSettings) {
        perform { c in
            let reopen = new.localInterfaceIP != c.settings.localInterfaceIP
            c.settings = new
            c.sender.configure(sourceName: new.sourceName, priority: UInt8(clamp(new.priority, 1, 200)))
            if reopen { c.sender.open(localInterfaceIP: new.localInterfaceIP) }
        }
    }

    public var latest: (states: [Int: FixtureState], frames: [UInt16: [UInt8]], status: EngineStatus) { snapshot.get() }
    public var lastError: String? { sender.lastError }
    public var packetsSent: UInt64 { sender.packetsSent }

    private func tick() {
        let jobs = pending.mutate { list -> [(OutputController) -> Void] in let l = list; list.removeAll(); return l }
        for j in jobs { j(self) }
        let now = Self.monotonicNow()
        let dt = clamp(now - lastTick, 0.001, 0.1)
        lastTick = now
        let music = musicProvider()
        let states = engine.tick(music: music, now: now, dt: dt)
        var frames = FixtureEncoder.frames(rig: engine.rig, states: states)
        if let base = frames.keys.sorted().first, let data = frames[base] {
            for m in settings.mirrorUniverses where frames[m] == nil && m >= 1 && m <= 63999 { frames[m] = data }
        }
        if settings.enabled {
            for (u, data) in frames {
                sender.send(universe: u, slots: data, mode: settings.mode, destination: settings.nodeIP)
            }
        }
        lastFrames = frames
        snapshot.set((states, frames, engine.status))
    }
}
