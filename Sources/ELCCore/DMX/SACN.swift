import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Builds ANSI E1.31-2016 (sACN) data packets.
public struct SACNPacketBuilder {
    public static let packetLength = 638
    public static let port: UInt16 = 5568

    public var cid: [UInt8]           // 16 bytes, unique per source
    public var sourceName: String
    public var priority: UInt8

    public init(cid: [UInt8], sourceName: String, priority: UInt8 = 100) {
        precondition(cid.count == 16, "CID must be 16 bytes")
        self.cid = cid
        self.sourceName = sourceName
        self.priority = priority
    }

    public static func multicastAddress(for universe: UInt16) -> String {
        "239.255.\(universe >> 8).\(universe & 0xFF)"
    }

    public func packet(universe: UInt16, sequence: UInt8, slots: [UInt8], terminated: Bool = false) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: Self.packetLength)
        func put16(_ v: UInt16, at i: Int) { p[i] = UInt8(v >> 8); p[i + 1] = UInt8(v & 0xFF) }
        func put32(_ v: UInt32, at i: Int) {
            p[i] = UInt8((v >> 24) & 0xFF); p[i + 1] = UInt8((v >> 16) & 0xFF)
            p[i + 2] = UInt8((v >> 8) & 0xFF); p[i + 3] = UInt8(v & 0xFF)
        }
        // Root layer
        put16(0x0010, at: 0)                       // preamble size
        put16(0x0000, at: 2)                       // postamble size
        let acnId: [UInt8] = [0x41, 0x53, 0x43, 0x2D, 0x45, 0x31, 0x2E, 0x31, 0x37, 0x00, 0x00, 0x00]
        for (i, b) in acnId.enumerated() { p[4 + i] = b }
        put16(0x7000 | UInt16(Self.packetLength - 16), at: 16)
        put32(0x0000_0004, at: 18)                 // VECTOR_ROOT_E131_DATA
        for i in 0..<16 { p[22 + i] = cid[i] }
        // Framing layer
        put16(0x7000 | UInt16(Self.packetLength - 38), at: 38)
        put32(0x0000_0002, at: 40)                 // VECTOR_E131_DATA_PACKET
        let nameBytes = Array(sourceName.utf8.prefix(63))
        for (i, b) in nameBytes.enumerated() { p[44 + i] = b }
        p[108] = min(priority, 200)
        put16(0, at: 109)                          // sync address
        p[111] = sequence
        p[112] = terminated ? 0x40 : 0x00          // options (bit 6 = stream terminated)
        put16(universe, at: 113)
        // DMP layer
        put16(0x7000 | UInt16(Self.packetLength - 115), at: 115)
        p[117] = 0x02                              // VECTOR_DMP_SET_PROPERTY
        p[118] = 0xA1                              // address & data type
        put16(0x0000, at: 119)                     // first property address
        put16(0x0001, at: 121)                     // address increment
        put16(513, at: 123)                        // property value count
        p[125] = 0x00                              // DMX start code
        let n = min(slots.count, 512)
        for i in 0..<n { p[126 + i] = slots[i] }
        return p
    }

    public static func randomCID() -> [UInt8] {
        let u = UUID().uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }
}

/// Sends sACN over UDP (unicast to the NodeGBx8's IP, or multicast).
public final class SACNSender: @unchecked Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case unicast, multicast
    }

    private var fd: Int32 = -1
    private var builder: SACNPacketBuilder
    private var sequences: [UInt16: UInt8] = [:]
    private let lock = NSLock()
    public private(set) var lastError: String?
    public private(set) var packetsSent: UInt64 = 0

    public init(cid: [UInt8], sourceName: String, priority: UInt8) {
        builder = SACNPacketBuilder(cid: cid, sourceName: sourceName, priority: priority)
    }

    deinit { closeSocket() }

    public func configure(sourceName: String, priority: UInt8) {
        lock.lock(); defer { lock.unlock() }
        builder.sourceName = sourceName
        builder.priority = priority
    }

    /// (Re)opens the socket. `localInterfaceIP` selects the network interface used for multicast.
    public func open(localInterfaceIP: String?) {
        lock.lock(); defer { lock.unlock() }
        closeSocketLocked()
        #if canImport(Darwin)
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #else
        let s = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard s >= 0 else { lastError = "socket() failed (errno \(errno))"; return }
        var ttl: UInt8 = 8
        setsockopt(s, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var loop: UInt8 = 0
        setsockopt(s, Int32(IPPROTO_IP), IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        if let ip = localInterfaceIP, !ip.isEmpty {
            var addr = in_addr()
            if inet_pton(AF_INET, ip, &addr) == 1 {
                setsockopt(s, Int32(IPPROTO_IP), IP_MULTICAST_IF, &addr, socklen_t(MemoryLayout<in_addr>.size))
                // Also bind so unicast leaves through the same interface.
                var local = sockaddr_in()
                local.sin_family = sa_family_t(AF_INET)
                local.sin_addr = addr
                local.sin_port = 0
                _ = withUnsafePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        fd = s
        lastError = nil
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        closeSocketLocked()
    }

    private func closeSocket() {
        lock.lock(); defer { lock.unlock() }
        closeSocketLocked()
    }

    private func closeSocketLocked() {
        if fd >= 0 {
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
            fd = -1
        }
    }

    /// Sends one universe. `destination` is the node IP for unicast; ignored for multicast.
    @discardableResult
    public func send(universe: UInt16, slots: [UInt8], mode: Mode, destination: String, terminated: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { lastError = "Socket not open"; return false }
        let seq = sequences[universe, default: 0] &+ 1
        sequences[universe] = seq
        let packet = builder.packet(universe: universe, sequence: seq, slots: slots, terminated: terminated)
        let host = mode == .multicast ? SACNPacketBuilder.multicastAddress(for: universe) : destination
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = SACNPacketBuilder.port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            lastError = "Invalid destination IP '\(host)'"
            return false
        }
        let sent = packet.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            lastError = "sendto failed: \(String(cString: strerror(errno)))"
            return false
        }
        packetsSent &+= 1
        lastError = nil
        return true
    }
}
