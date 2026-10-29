import Foundation

/// A finished insight card as shown in the feed.
public struct InsightCard: Identifiable, Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case gemma, template, safety }
    public var id: UUID
    public var event: InsightEvent
    public var text: String
    public var source: Source
    public var firstTokenMs: Double?
    public var totalMs: Double?
    public var isStreaming: Bool
    public init(event: InsightEvent, text: String = "", source: Source = .gemma, firstTokenMs: Double? = nil, totalMs: Double? = nil, isStreaming: Bool = true) {
        self.id = event.id; self.event = event; self.text = text; self.source = source
        self.firstTokenMs = firstTokenMs; self.totalMs = totalMs; self.isStreaming = isStreaming
    }
}

/// The evidence functions behind chat tools. Each returns a JSON-friendly dictionary.
/// The LiteRT-LM tool structs in the app are thin wrappers around these.
public struct HealthTools {
    public let store: MetricsStore
    public let memory: MemoryStore
    public let cards: [InsightCard]
    /// The single health store; nil only where there is none (history tools then say so).
    public let db: HealthDB?
    /// Today's totals to show instead of the database's (demo and replay, which are never stored).
    public let todayTotals: FitnessTotals?
    public let now: Date

    public init(store: MetricsStore, memory: MemoryStore, cards: [InsightCard], db: HealthDB? = nil,
                todayTotals: FitnessTotals? = nil, now: Date = Date()) {
        self.store = store; self.memory = memory; self.cards = cards; self.db = db; self.todayTotals = todayTotals; self.now = now
    }

    // MARK: stored history (HealthDB, 30 s windows)

    private static let bucketFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f }()
    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE MMM d"; return f }()

    /// (mean, min, max) of one metric in a stored window; motion is the window's ENMO in mg.
    private static func value(_ m: Metric, _ w: StoredWindow) -> (mean: Double, min: Double, max: Double)? {
        switch m {
        case .heartRate: return w.hrAvg.map { ($0, w.hrMin ?? $0, w.hrMax ?? $0) }
        case .hrv: return w.hrv.map { ($0, $0, $0) }
        case .spo2: return w.spo2.map { ($0, $0, $0) }
        case .skinTemp: return w.skinTemp.map { ($0, $0, $0) }
        case .motion: return w.worn ? (w.enmoMg, w.enmoMg, w.enmoMg) : nil
        }
    }

    /// Resting heart rate: 10th percentile of still windows (all windows if fewer than 10 minutes are still).
    static func restingHR(_ windows: [StoredWindow]) -> Double? {
        let still = windows.filter { $0.label == .stationary }.compactMap { $0.hrAvg }
        let pool = still.count >= 20 ? still : windows.compactMap { $0.hrAvg }
        guard pool.count >= 10 else { return nil }
        return pool.sorted()[Int(Double(pool.count - 1) * 0.1)]
    }

    /// One metric over the past hours, bucketed: 10 min up to 3 h, hourly up to 2 days, 6 h beyond.
    public func history(metric name: String, hours: Int) -> [String: Any] {
        guard let db else { return ["error": "history unavailable"] }
        guard let m = Metric(loose: name) else {
            return ["error": "unknown metric '\(name)'. Use one of: heart_rate, spo2, skin_temp, motion"]
        }
        let h = max(1, min(hours, 168))
        let from = now.addingTimeInterval(-Double(h) * 3600)
        let windows = db.windows(from: from, to: now)
        let vals = windows.compactMap { w in Self.value(m, w).map { (w.start, $0) } }
        guard !vals.isEmpty else {
            return ["metric": m.rawValue, "hours": h, "result": "no stored band data in this period"]
        }
        let bucket: TimeInterval = h <= 3 ? 600 : h <= 48 ? 3600 : 6 * 3600
        let d = (m == .skinTemp || m == .motion) ? 2 : 0
        var buckets: [[String: Any]] = []
        var t = from
        while t < now {
            let end = t.addingTimeInterval(bucket)
            let inB = vals.filter { $0.0 >= t.timeIntervalSince1970 && $0.0 < end.timeIntervalSince1970 }.map { $0.1 }
            if !inB.isEmpty {
                buckets.append(["from": Self.bucketFormat.string(from: t), "mean": Self.r(Stats.mean(inB.map { $0.mean }), d),
                                "min": Self.r(inB.map { $0.min }.min(), d), "max": Self.r(inB.map { $0.max }.max(), d),
                                "minutes_of_data": Double(inB.count) / 2])
            }
            t = end
        }
        var out: [String: Any] = ["metric": m.rawValue, "unit": m == .motion ? "mg" : m.unit, "hours": h,
                                  "minutes_of_data": Double(vals.count) / 2,
                                  "mean": Self.r(Stats.mean(vals.map { $0.1.mean }), d),
                                  "min": Self.r(vals.map { $0.1.min }.min(), d), "max": Self.r(vals.map { $0.1.max }.max(), d),
                                  "buckets": buckets]
        if m == .heartRate, let r = Self.restingHR(windows) { out["resting_heart_rate_estimate"] = Self.r(r) }
        return out
    }

    /// One row per day for the past `days` days (today included), newest first.
    public func dailySummary(days: Int) -> [String: Any] {
        guard let db else { return ["error": "history unavailable"] }
        let n = max(1, min(days, 14))
        let summaries = db.lastDays(n, endingAt: now)
        var rows: [[String: Any]] = []
        for (i, s) in summaries.enumerated().reversed() {
            guard s.windows > 0 else { continue }
            let back = summaries.count - 1 - i
            var row: [String: Any] = ["day": back == 0 ? "today" : back == 1 ? "yesterday" : Self.dayFormat.string(from: s.start),
                                      "minutes_worn": s.wornMinutes,
                                      "mean_heart_rate": Self.r(s.hrAvg), "max_heart_rate": Self.r(s.hrMax),
                                      "mean_spo2": Self.r(s.spo2), "mean_skin_temp": Self.r(s.skinTemp, 1),
                                      "active_minutes": Self.r(s.totals.activeMinutes), "steps": s.totals.steps,
                                      "active_kcal": Self.r(s.totals.activeKcal)]
            if let r = Self.restingHR(db.windows(from: s.start, to: s.end)) { row["resting_heart_rate"] = Self.r(r) }
            rows.append(row)
        }
        return ["days": n, "summary": rows.isEmpty ? ["no stored band data yet"] : rows]
    }

    /// Today's steps and activity. Band windows are written to the database as each one finishes, so
    /// its day total already includes this session; adding the live timeline would count it twice.
    private func today() -> FitnessTotals {
        todayTotals ?? db?.totals(on: now) ?? store.fitness.timeline.today(now: now)
    }

    static func r(_ v: Double?, _ d: Int = 0) -> Any { v.map { Double(Fmt.n($0, d)) ?? $0 } ?? NSNull() }

    private func age(_ t: Date) -> String {
        let s = Int(now.timeIntervalSince(t))
        return s < 90 ? "\(s) s ago" : "\(s / 60) min ago"
    }

    public func liveMetrics(windowSeconds: Int) -> [String: Any] {
        let w = TimeInterval(max(10, min(windowSeconds, 3600)))
        var out: [String: Any] = ["window_seconds": Int(w), "band_worn": store.isWorn]
        for m in [Metric.heartRate, .spo2, .skinTemp] {
            if let s = store.stats(m, seconds: w, now: now) {
                let d = m == .skinTemp ? 1 : 0
                out[m.rawValue] = ["latest": Self.r(s.latest, d), "mean": Self.r(s.mean, d), "min": Self.r(s.min, d), "max": Self.r(s.max, d), "unit": m.unit]
            } else {
                out[m.rawValue] = "no reliable data in this window"
            }
        }
        if let a = store.currentActivity(now: now) { out["activity"] = a.label.lowercased() }
        let t = today()
        if store.fitness.hasData || t.steps > 0 {
            out["steps_today"] = t.steps
            out["active_kcal_today"] = Self.r(t.activeKcal)
            out["active_minutes_today"] = Self.r(t.activeMinutes)
            out["mvpa_minutes_today"] = Self.r(t.mvpaMinutes)
        }
        let b = store.baseline
        if b.isEstablished {
            out["personal_baseline"] = ["resting_heart_rate": Self.r(b.heartRate), "skin_temp": Self.r(b.skinTemp, 1)]
        } else {
            out["personal_baseline"] = "still calibrating"
        }
        return out
    }

    public func trend(metric name: String, minutes: Int) -> [String: Any] {
        guard let m = Metric(loose: name) else {
            return ["error": "unknown metric '\(name)'. Use one of: heart_rate, spo2, skin_temp, motion"]
        }
        let secs = TimeInterval(max(1, min(minutes, 60)) * 60)
        guard let s = store.stats(m, seconds: secs, now: now) else {
            return ["metric": m.rawValue, "minutes": Int(secs / 60), "result": "no data in this window"]
        }
        let d = (m == .skinTemp || m == .motion) ? 2 : 0
        let pts = store.series(m, seconds: secs, maxPoints: 12, now: now).map { p -> [String: Any] in
            ["minutes_ago": Self.r(now.timeIntervalSince(p.t) / 60, 1), "value": Self.r(p.value, d)]
        }
        return ["metric": m.rawValue, "unit": m.unit, "minutes": Int(secs / 60),
                "mean": Self.r(s.mean, d), "min": Self.r(s.min, d), "max": Self.r(s.max, d), "latest": Self.r(s.latest, d),
                "change_per_minute": Self.r(s.slopePerMinute, 2), "points": pts]
    }

    public func activityTimeline(minutes: Int) -> [String: Any] {
        let secs = TimeInterval(max(1, min(minutes, 60)) * 60)
        let fitness = store.fitness.timeline.windows(from: now.addingTimeInterval(-secs).timeIntervalSince1970, to: now.timeIntervalSince1970)
        if !fitness.isEmpty { return ["minutes": Int(secs / 60), "segments": fitnessSegments(fitness.map { $0.interval })] }
        let segs = store.activityTimeline(seconds: secs, now: now).map { seg -> [String: Any] in
            let hr = store.points(.heartRate, since: seg.start).filter { $0.t <= seg.end.addingTimeInterval(5) }.map { $0.value }
            return ["activity": seg.activity.label.lowercased(), "started": age(seg.start),
                    "duration_seconds": Int(seg.end.timeIntervalSince(seg.start)) + 5, "mean_heart_rate": Self.r(Stats.mean(hr))]
        }
        return ["minutes": Int(secs / 60), "segments": segs.isEmpty ? ["no activity data yet"] : segs]
    }

    /// Fitness windows merged into segments of consecutive same-label windows.
    private func fitnessSegments(_ windows: [FitnessInterval]) -> [[String: Any]] {
        var groups: [[FitnessInterval]] = []
        for w in windows {
            if let last = groups.last?.last, last.label == w.label, abs(w.start - last.end) < 1 { groups[groups.count - 1].append(w) } else { groups.append([w]) }
        }
        return groups.map { g -> [String: Any] in
            let hr = g.map { $0.hr }.filter { $0 > 0 }
            var seg: [String: Any] = ["activity": g[0].label.rawValue.replacingOccurrences(of: "_", with: " "),
                                      "started": age(Date(timeIntervalSince1970: g[0].start)),
                                      "duration_seconds": Int((g.last!.end - g[0].start).rounded()),
                                      "mean_heart_rate": Self.r(Stats.mean(hr))]
            let steps = g.reduce(0) { $0 + $1.metrics.steps }
            if steps > 0 { seg["steps"] = steps }
            seg["active_kcal"] = Self.r(g.reduce(0) { $0 + $1.metrics.kcal }, 1)
            return seg
        }
    }

    /// Recent events and insights: this session's cards plus the saved insight memories (falls,
    /// workouts, heart-rate alerts) from the last 48 hours, so they survive an app restart.
    public func recentInsights(count: Int) -> [String: Any] {
        // Gemma tends to ask for 1; with so few it missed a fall just behind the newest event.
        let n = max(8, min(count, 12))
        var items: [(Date, [String: Any])] = cards.filter { !$0.isStreaming }.map {
            ($0.event.createdAt, ["when": age($0.event.createdAt), "type": $0.event.kind.title, "card": $0.text])
        }
        let saved = memory.facts.filter { $0.source == "insight" && now.timeIntervalSince($0.createdAt) < 48 * 3600 }
        for f in saved where !items.contains(where: { abs($0.0.timeIntervalSince(f.createdAt)) < 5 }) {
            items.append((f.createdAt, ["when": age(f.createdAt), "event": f.text]))
        }
        let out = items.sorted { $0.0 > $1.0 }.prefix(n).map { $0.1 }
        return ["insights": out.isEmpty ? ["none yet"] : Array(out)]
    }

    public func recallMemory(query: String) -> [String: Any] {
        let hits = memory.recall(query)
        return ["query": query, "facts": hits.isEmpty ? ["nothing relevant remembered"] : hits.map { "\($0.text) (told \(age($0.createdAt)))" }]
    }

    /// Called by Gemma when the user shares something about themselves.
    public func saveMemory(fact: String) -> [String: Any] {
        let t = fact.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard t.count >= 5, t.count <= 200 else { return ["saved": false, "reason": "fact should be one short sentence"] }
        let lower = t.lowercased()
        if memory.facts.contains(where: { $0.text.lowercased().contains(lower) || lower.contains($0.text.lowercased()) }) {
            return ["saved": false, "reason": "already remembered"]
        }
        memory.add(t, source: "chat")
        return ["saved": true, "fact": t]
    }

    public static func json(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "\(obj)" }
        return s
    }
}

public enum ChatPrompts {
    public static func system(profile: UserProfile, now: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE h:mm a"
        var s = """
        You are Gemma, a women's health companion inside the Bolt app, running entirely on this phone with no internet. You can see live data from the user's wearable band through tools. Never mention any brand name for the band.
        Rules:
        - For any number about the user, call a tool first. Never guess or invent measurements.
        - Answer in at most 3 short sentences, plain words, lead with the answer. Quote the numbers the tools return, as digits.
        - You only see data. Never guess how the user feels.
        - Describe and suggest; never diagnose. Only if the user mentions symptoms such as chest pain, fainting or trouble breathing, tell them clearly to get urgent help.
        - For earlier today, yesterday or past days, use get_history or get_daily_summary; live tools only cover the current session.
        - When the user tells you something about themselves (food, coffee, alcohol, sleep, exercise, falls or injuries, symptoms, medication, cycle, mood), call save_memory with one short first-person sentence, then answer.
        - The facts and events listed below are true. If one answers the question (for example a fall the band detected), answer from it directly. For falls, workouts or alerts not listed, call get_recent_insights.
        - Answer the new message; never repeat an earlier answer word for word.
        - If data is missing or the band isn't worn, say so.
        Local time: \(f.string(from: now)).
        """
        if !profile.summary.isEmpty { s += "\nAbout the user: \(profile.summary)." }
        return s
    }

    public static let suggestions = [
        "How is my heart doing right now?",
        "How did I recover from that last effort?",
        "Should I have a coffee before my run later?",
        "What has my heart rate done in the last 10 minutes?",
        "How does today compare to yesterday?",
    ]
}
