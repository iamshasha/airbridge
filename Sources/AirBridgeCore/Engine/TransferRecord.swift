import Foundation
import Observation

/// UI-facing state of one transfer. Byte counters live in the engine; `Node` samples them a few times a second.
@MainActor @Observable
public final class TransferRecord: Identifiable {
    public enum Direction: Sendable { case outgoing, incoming }
    public enum State: Equatable, Sendable {
        case connecting, waitingForAcceptance, active, done, failed(String), declined
        public var isFinished: Bool {
            switch self { case .done, .failed, .declined: return true; default: return false }
        }
    }

    public let id: String
    public let direction: Direction
    public let peerName: String
    public let title: String
    public let sync: Bool
    public internal(set) var total: Int64
    public internal(set) var bytes: Int64 = 0
    public internal(set) var bytesPerSecond: Double = 0
    public internal(set) var state: State = .connecting
    public internal(set) var startedAt = Date()
    public internal(set) var finishedAt: Date?
    public internal(set) var savedURLs: [URL] = []

    @ObservationIgnored var counter: Locked<Int64>?
    @ObservationIgnored private var lastSample: (Date, Int64)?

    init(id: String, direction: Direction, peerName: String, title: String, total: Int64, sync: Bool) {
        self.id = id
        self.direction = direction
        self.peerName = peerName
        self.title = title
        self.total = total
        self.sync = sync
    }

    public var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : (state == .done ? 1 : 0) }

    /// Average throughput over the whole active phase once finished.
    public var averageBytesPerSecond: Double {
        guard let end = finishedAt else { return bytesPerSecond }
        let duration = end.timeIntervalSince(startedAt)
        return duration > 0 ? Double(bytes) / duration : 0
    }

    func sample() {
        guard let counter else { return }
        let now = Date()
        let value = counter.current
        if let (t, b) = lastSample, now.timeIntervalSince(t) > 0.2 {
            let instant = Double(value - b) / now.timeIntervalSince(t)
            bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.6 + instant * 0.4
            lastSample = (now, value)
        } else if lastSample == nil {
            lastSample = (now, value)
        }
        bytes = value
    }

    func activate(counter: Locked<Int64>) {
        self.counter = counter
        state = .active
        startedAt = Date()
    }

    func finish(_ state: State) {
        sample()
        if state == .done { bytes = total }
        self.state = state
        finishedAt = Date()
        counter = nil
    }
}

public struct ReceivedText: Identifiable, Sendable {
    public let id = UUID()
    public let from: String
    public let text: String
    public let date = Date()
}

/// Something the user has to decide on: an incoming offer or a pairing request.
@MainActor
public final class Prompt: Identifiable {
    public enum Kind {
        case offer(items: [FileItem], total: Int64)
        case pairing(code: String)
    }

    public let id = UUID()
    public let peerName: String
    public let peerPlatform: String
    public let fingerprint: String
    public let kind: Kind
    private var continuation: CheckedContinuation<Bool, Never>?

    init(peerName: String, peerPlatform: String, fingerprint: String, kind: Kind, continuation: CheckedContinuation<Bool, Never>) {
        self.peerName = peerName
        self.peerPlatform = peerPlatform
        self.fingerprint = fingerprint
        self.kind = kind
        self.continuation = continuation
    }

    func resolve(_ accepted: Bool) {
        continuation?.resume(returning: accepted)
        continuation = nil
    }

    public var summary: String {
        switch kind {
        case .pairing: return "\(peerName) wants to pair"
        case .offer(let items, let total):
            let files = items.filter { $0.dir != true }
            let tops = Set(items.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
            let what = tops.count == 1 ? tops.first! : "\(files.count) files"
            return "\(peerName) wants to send \(what) (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))"
        }
    }
}
