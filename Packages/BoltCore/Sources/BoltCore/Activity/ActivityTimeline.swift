import Foundation

/// Day aggregates: sleeping and not-worn windows contribute nothing; every other window is 0.5 min.
public struct FitnessTotals: Equatable, Sendable {
    public var steps = 0
    public var activeMinutes = 0.0
    public var mvpaMinutes = 0.0
    public var lightMinutes = 0.0
    public var mediumMinutes = 0.0
    public var highMinutes = 0.0
    public var activeKcal = 0.0
    /// Minutes in walk/run windows that counted steps.
    public var walkingMinutes = 0.0
    /// Mean cadence (steps/min) over those windows; nil until some walking is counted.
    public var walkingCadence: Double?
    public init() {}
}

/// Finalized windows keyed by their 30 s grid start (unix seconds), so overlapping data is not double counted.
public struct FitnessTimeline: Sendable {
    public enum Source: Int, Sendable { case live = 0, file = 1 }

    public struct Entry: Equatable, Sendable {
        public var interval: FitnessInterval
        public var source: Source
        public var key: Int64 { FitnessTimeline.key(interval.start) }
    }

    public private(set) var entries: [Int64: Entry] = [:]

    public init() {}

    public static func key(_ start: Double) -> Int64 { Int64(start.rounded()) }

    /// Store `intervals`; returns how many were kept (a file window is never replaced by a live one).
    @discardableResult
    public mutating func insert(_ intervals: [FitnessInterval], source: Source) -> Int {
        var kept = 0
        for i in intervals {
            let k = Self.key(i.start)
            if let old = entries[k], old.source == .file, source == .live { continue }
            entries[k] = Entry(interval: i, source: source)
            kept += 1
        }
        return kept
    }

    /// Entries with `from <= start < to` (unix seconds), ordered by time.
    public func windows(from: Double, to: Double) -> [Entry] {
        entries.values.filter { $0.interval.start >= from && $0.interval.start < to }.sorted { $0.interval.start < $1.interval.start }
    }

    public func totals(from: Double, to: Double) -> FitnessTotals {
        var t = FitnessTotals()
        var cadenceSum = 0.0
        for e in windows(from: from, to: to) {
            let i = e.interval
            guard i.label != .sleeping && i.label != .notWorn else { continue }
            t.steps += i.metrics.steps
            t.activeKcal += i.metrics.kcal
            if i.active { t.activeMinutes += 0.5 }
            if i.metrics.band >= 2 { t.mvpaMinutes += 0.5 }
            if i.metrics.band == 1 { t.lightMinutes += 0.5 }
            if i.metrics.band == 2 { t.mediumMinutes += 0.5 }
            if i.metrics.band == 3 { t.highMinutes += 0.5 }
            if i.label.isLocomotor, i.metrics.steps > 0 { t.walkingMinutes += 0.5; cadenceSum += i.metrics.cadence }
        }
        if t.walkingMinutes > 0 { t.walkingCadence = cadenceSum / (t.walkingMinutes * 2) }
        return t
    }

    /// Totals for the calendar day containing `now`.
    public func today(now: Date = Date(), calendar: Calendar = .current) -> FitnessTotals {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return totals(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970)
    }
}

/// Published activity state: the timeline, the latest window, and any long bouts.
public struct FitnessState: Sendable {
    public var timeline = FitnessTimeline()
    public var latest: FitnessInterval?
    /// Walk/run/cycle bouts of >= 5 min from the current day's windows.
    public var bouts: [FitnessBout] = []
    public init() {}
    public var hasData: Bool { latest != nil }
}
