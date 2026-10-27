import Foundation

/// Flat control message (PROTOCOL.md §3). Kept flat so non-Swift ports can map it trivially.
public struct ControlMessage: Codable, Sendable {
    public var t: String
    public var transferId: String?
    public var items: [FileItem]?
    public var total: Int64?
    public var streams: Int?
    public var sync: Bool?
    public var text: String?
    public var path: String?
    public var paths: [String]?
    public var entries: [RemoteEntry]?
    public var reason: String?

    public init(_ t: String) { self.t = t }

    /// Reply to a request that needs trust when the sender is not (or no longer) paired.
    static var notPaired: ControlMessage {
        var m = ControlMessage("notPaired"); m.reason = "This device is not paired"; return m
    }

    static func error(_ reason: String) -> ControlMessage {
        var m = ControlMessage("error"); m.reason = reason; return m
    }
}

public struct FileItem: Codable, Sendable, Hashable {
    public var i: Int
    public var path: String
    public var size: Int64
    public var dir: Bool?
}

public struct RemoteEntry: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var size: Int64
    public var dir: Bool
    public var id: String { name }
}
