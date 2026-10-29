import Foundation

/// What the "Under the hood" screen shows: every model call, tool call and timing, all on-device.
public struct TraceEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case engine, card, chat, tool, activity, band, robot, warning }
    public var id = UUID()
    public var time: Date
    public var kind: Kind
    public var title: String
    public var detail: String
    public var ms: Double?
    public init(time: Date = Date(), kind: Kind, title: String, detail: String = "", ms: Double? = nil) {
        self.time = time; self.kind = kind; self.title = title; self.detail = detail; self.ms = ms
    }
}

public struct TraceLog: Sendable {
    public private(set) var entries: [TraceEntry] = []
    public var limit = 300
    public init() {}
    public mutating func add(_ e: TraceEntry) {
        entries.append(e)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }
    public mutating func clear() { entries = [] }

    public func medianMs(_ kind: TraceEntry.Kind) -> Double? {
        Stats.median(entries.filter { $0.kind == kind }.compactMap { $0.ms })
    }
}
