import Foundation

public enum AirBridgeError: Error, LocalizedError, Equatable {
    case connectionClosed
    case connectFailed(String)
    case protocolViolation(String)
    case authenticationFailed
    case declined(String)
    case notTrusted
    case timeout

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: return "Connection closed"
        case .connectFailed(let s): return "Could not connect: \(s)"
        case .protocolViolation(let s): return "Protocol error: \(s)"
        case .authenticationFailed: return "Device authentication failed"
        case .declined(let s): return s.isEmpty ? "Declined" : "Declined: \(s)"
        case .notTrusted: return "The other device is no longer paired with this one. Pair again to continue."
        case .timeout: return "Timed out"
        }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    func readBE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        let start = startIndex + offset
        Swift.withUnsafeMutableBytes(of: &value) { dst in
            copyBytes(to: dst, from: start ..< start + MemoryLayout<T>.size)
        }
        return T(bigEndian: value)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Simple lock wrapper used by the engine's background components.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
    var current: Value { withLock { $0 } }
}
