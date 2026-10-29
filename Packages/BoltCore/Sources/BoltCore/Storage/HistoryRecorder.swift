import Foundation

/// Keeps `HealthDB` in step with Fitness. Each sync writes the windows Fitness added or relabelled since
/// the last one (Fitness can revise any window of the day), so stored totals match
/// `FitnessTimeline.totals` for the session. Not thread-safe: use it from the main actor.
public final class HistoryRecorder {
    private let db: HealthDB
    /// What was last written for each window key this session.
    private var written: [Int64: FitnessInterval] = [:]

    public init(db: HealthDB) { self.db = db }

    /// Forget what was written, e.g. when a new session starts with a fresh Fitness engine.
    public func reset() { written = [:] }

    /// Writes windows starting at or after `since` (unix seconds, usually the start of today) that
    /// are new or changed, with the vitals `store` holds for each. Returns how many were written.
    @discardableResult
    public func sync(_ timeline: FitnessTimeline, store: MetricsStore, since: Double) -> Int {
        let changed = timeline.windows(from: since, to: .greatestFiniteMagnitude).map { $0.interval }
            .filter { written[FitnessTimeline.key($0.start)] != $0 }
        guard !changed.isEmpty else { return 0 }
        db.record(windows: changed.map { i in
            let from = Date(timeIntervalSince1970: i.start), to = Date(timeIntervalSince1970: i.end)
            return StoredWindow(interval: i, hr: store.stats(.heartRate, from: from, to: to), hrv: store.stats(.hrv, from: from, to: to),
                                spo2: store.stats(.spo2, from: from, to: to), skinTemp: store.stats(.skinTemp, from: from, to: to),
                                worn: i.label != .notWorn)
        })
        for i in changed { written[FitnessTimeline.key(i.start)] = i }
        return changed.count
    }
}
