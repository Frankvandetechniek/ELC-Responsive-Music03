import Foundation

@inline(__always) public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}

@inline(__always) public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

@inline(__always) public func smoothstep(_ x: Double) -> Double {
    let t = clamp(x, 0, 1)
    return t * t * (3 - 2 * t)
}

/// Positive modulo (always returns a value in 0..<m).
@inline(__always) public func fmodPositive(_ x: Double, _ m: Double) -> Double {
    let r = x.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m : r
}

@inline(__always) public func toByte(_ v: Double) -> UInt8 {
    UInt8(clamp((v * 255).rounded(), 0, 255))
}

@inline(__always) public func degToRad(_ d: Double) -> Double { d * .pi / 180 }
@inline(__always) public func radToDeg(_ r: Double) -> Double { r * 180 / .pi }

/// Tiny lock-protected box used to hand data between the audio thread,
/// the DMX output thread and the UI.
public final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    public init(_ value: T) { self.value = value }
    public func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    public func set(_ newValue: T) {
        lock.lock(); value = newValue; lock.unlock()
    }
    @discardableResult
    public func mutate<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Deterministic, fast random generator (xorshift64*), so looks can be
/// reproduced and tests are stable.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// Exponential smoothing helper that is frame-rate independent.
@inline(__always) public func smoothTowards(_ current: Double, _ target: Double, dt: Double, timeConstant: Double) -> Double {
    if timeConstant <= 0 { return target }
    let a = 1 - exp(-dt / timeConstant)
    return current + (target - current) * a
}

/// Cheap deterministic hash noise in 0...1 for an integer input.
@inline(__always) public func hashNoise(_ n: Int, seed: Int = 0) -> Double {
    var x = UInt64(bitPattern: Int64(n &* 374761393 &+ seed &* 668265263))
    x = (x ^ (x >> 13)) &* 1274126177
    x = x ^ (x >> 16)
    return Double(x & 0xFFFF) / 65535.0
}
