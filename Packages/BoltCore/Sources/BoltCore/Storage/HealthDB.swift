import Foundation

/// One Fitness 30 s window with the vitals seen during it: the unit of stored history.
public struct StoredWindow: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var label: FitnessLabel
    public var active: Bool
    public var steps: Int
    public var cadence: Double
    public var kcal: Double
    public var enmoMg: Double
    public var intensityBand: Int
    public var hrAvg: Double?
    public var hrMin: Double?
    public var hrMax: Double?
    public var hrv: Double?
    public var spo2: Double?
    public var skinTemp: Double?
    public var worn: Bool

    public init(start: Double, end: Double, label: FitnessLabel, active: Bool, steps: Int, cadence: Double, kcal: Double,
                enmoMg: Double, intensityBand: Int, hrAvg: Double?, hrMin: Double?, hrMax: Double?,
                hrv: Double?, spo2: Double?, skinTemp: Double?, worn: Bool) {
        self.start = start; self.end = end; self.label = label; self.active = active
        self.steps = steps; self.cadence = cadence; self.kcal = kcal; self.enmoMg = enmoMg; self.intensityBand = intensityBand
        self.hrAvg = hrAvg; self.hrMin = hrMin; self.hrMax = hrMax
        self.hrv = hrv; self.spo2 = spo2; self.skinTemp = skinTemp; self.worn = worn
    }

    /// A row from a classified window and the store's stats over the same 30 s.
    public init(interval i: FitnessInterval, hr: WindowStats?, hrv: WindowStats?, spo2: WindowStats?, skinTemp: WindowStats?, worn: Bool) {
        self.init(start: i.start, end: i.end, label: i.label, active: i.active, steps: i.metrics.steps,
                  cadence: i.metrics.cadence, kcal: i.metrics.kcal, enmoMg: i.metrics.enmoMg, intensityBand: i.metrics.band,
                  hrAvg: hr?.mean, hrMin: hr?.min, hrMax: hr?.max, hrv: hrv?.mean, spo2: spo2?.mean, skinTemp: skinTemp?.mean,
                  worn: worn)
    }

    /// Back to the shape the Live view shows. `hr` is 0 when no heart rate was seen, as in Fitness.
    public var interval: FitnessInterval {
        var m = FitnessMetrics()
        m.steps = steps; m.cadence = cadence; m.kcal = kcal; m.enmoMg = enmoMg; m.band = intensityBand
        m.hrAvailable = hrAvg != nil
        return FitnessInterval(start: start, end: end, label: label, metrics: m, active: active, hr: hrAvg ?? 0)
    }
}

/// Aggregates over a span of stored windows (an hour or a local day).
public struct HealthSummary: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var windows = 0
    /// Same rules as `FitnessTimeline.totals`: sleeping and not-worn windows add nothing.
    public var totals = FitnessTotals()
    public var hrMin: Double?
    public var hrAvg: Double?
    public var hrMax: Double?
    public var hrv: Double?
    public var spo2: Double?
    public var skinTemp: Double?
    public var wornMinutes = 0.0
}

/// On-device health history in one SQLite file: profile, 30 s windows, baselines and insight cards.
/// Nothing here leaves the phone. Not thread-safe: use it from the main actor, like `MetricsStore`.
public final class HealthDB {
    public static let currentVersion = 1

    private let url: URL?
    private let calendar: Calendar
    private var conn: SQLiteConnection

    /// `url` nil keeps the database in memory (tests, previews).
    public init(url: URL?, calendar: Calendar = .current) throws {
        self.url = url
        self.calendar = calendar
        conn = try Self.open(url)
    }

    private static func open(_ url: URL?) throws -> SQLiteConnection {
        if let url {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #if os(iOS)
            // Readable while locked after the first unlock, so a band session can keep writing.
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
            #endif
            // Stays on this phone: not in iCloud or computer backups.
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var d = dir; try? d.setResourceValues(values)
        }
        let c = try SQLiteConnection(path: url?.path)
        try migrate(c)
        return c
    }

    private static func migrate(_ c: SQLiteConnection) throws {
        let version = try c.scalar("PRAGMA user_version") ?? 0
        guard version < currentVersion else { return }
        try c.transaction {
            if version < 1 {
                try c.exec("""
                CREATE TABLE profile (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  name TEXT NOT NULL, age INTEGER, goals_json TEXT NOT NULL, notes TEXT NOT NULL,
                  onboarded_at REAL, updated_at REAL NOT NULL);
                CREATE TABLE windows (
                  start INTEGER PRIMARY KEY, end INTEGER NOT NULL,
                  hr_avg REAL, hr_min REAL, hr_max REAL, hrv REAL, spo2 REAL, skin_temp REAL,
                  steps INTEGER NOT NULL, cadence REAL NOT NULL, kcal REAL NOT NULL, enmo_mg REAL NOT NULL,
                  intensity_band INTEGER NOT NULL, label TEXT NOT NULL, active INTEGER NOT NULL, worn INTEGER NOT NULL);
                CREATE TABLE baselines (
                  t REAL PRIMARY KEY, hr REAL, hrv REAL, skin_temp REAL, established_at REAL);
                CREATE TABLE cards (
                  id TEXT PRIMARY KEY, t REAL NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL,
                  text TEXT NOT NULL, json TEXT NOT NULL);
                CREATE INDEX cards_t ON cards(t);
                """)
            }
            try c.exec("PRAGMA user_version = \(currentVersion)")
        }
    }

    // MARK: profile

    public func saveProfile(_ p: UserProfile, at now: Date = Date()) {
        let goals = (try? JSONEncoder().encode(p.goals)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try? conn.run("""
            INSERT INTO profile (id, name, age, goals_json, notes, updated_at) VALUES (1, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, age = excluded.age, goals_json = excluded.goals_json,
              notes = excluded.notes, updated_at = excluded.updated_at
            """, [.text(p.name), .of(p.age), .text(goals), .text(p.notes), .double(now.timeIntervalSince1970)])
    }

    public func loadProfile() -> UserProfile? {
        var p: UserProfile?
        try? conn.query("SELECT name, age, goals_json, notes FROM profile WHERE id = 1") { r in
            var u = UserProfile()
            u.name = r.text(0) ?? ""
            u.age = r.optInt(1)
            u.goals = r.text(2).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            u.notes = r.text(3) ?? ""
            p = u
        }
        return p
    }

    /// Stamps when onboarding finished. Creates an empty profile row if none exists yet.
    public func markOnboarded(at date: Date = Date()) {
        if loadProfile() == nil { saveProfile(UserProfile(), at: date) }
        try? conn.run("UPDATE profile SET onboarded_at = ? WHERE id = 1", [.double(date.timeIntervalSince1970)])
    }

    public var onboardedAt: Date? {
        var t: Double?
        try? conn.query("SELECT onboarded_at FROM profile WHERE id = 1") { t = $0.optDouble(0) }
        return t.map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: windows

    /// Insert, or update the window with the same start: Fitness can relabel recent windows, and a
    /// `/metrics` file window replaces a live one. Vitals already stored are kept when the new row has none.
    public func record(window w: StoredWindow) { record(windows: [w]) }

    /// Several windows in one transaction.
    public func record(windows: [StoredWindow]) {
        guard !windows.isEmpty else { return }
        try? conn.transaction {
            for w in windows {
                try conn.run("""
                    INSERT INTO windows (start, end, hr_avg, hr_min, hr_max, hrv, spo2, skin_temp, steps, cadence,
                      kcal, enmo_mg, intensity_band, label, active, worn) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(start) DO UPDATE SET end = excluded.end,
                      hr_avg = COALESCE(excluded.hr_avg, hr_avg), hr_min = COALESCE(excluded.hr_min, hr_min),
                      hr_max = COALESCE(excluded.hr_max, hr_max), hrv = COALESCE(excluded.hrv, hrv),
                      spo2 = COALESCE(excluded.spo2, spo2), skin_temp = COALESCE(excluded.skin_temp, skin_temp),
                      steps = excluded.steps, cadence = excluded.cadence, kcal = excluded.kcal, enmo_mg = excluded.enmo_mg,
                      intensity_band = excluded.intensity_band, label = excluded.label, active = excluded.active,
                      worn = MAX(excluded.worn, worn)
                    """, [.int(Int64(w.start)), .int(Int64(w.end)), .of(w.hrAvg), .of(w.hrMin), .of(w.hrMax), .of(w.hrv),
                          .of(w.spo2), .of(w.skinTemp), .int(Int64(w.steps)), .double(w.cadence), .double(w.kcal),
                          .double(w.enmoMg), .int(Int64(w.intensityBand)), .text(w.label.rawValue),
                          .int(w.active ? 1 : 0), .int(w.worn ? 1 : 0)])
            }
        }
    }

    /// Stored windows starting in `[from, to)`, oldest first.
    public func windows(from: Date, to: Date) -> [StoredWindow] {
        var out: [StoredWindow] = []
        try? conn.query("""
            SELECT start, end, label, active, steps, cadence, kcal, enmo_mg, intensity_band,
              hr_avg, hr_min, hr_max, hrv, spo2, skin_temp, worn
            FROM windows WHERE start >= ? AND start < ? ORDER BY start
            """, [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]) { r in
            out.append(StoredWindow(start: r.double(0), end: r.double(1), label: FitnessLabel(rawValue: r.text(2) ?? "") ?? .uncertain,
                                    active: r.int(3) != 0, steps: r.int(4), cadence: r.double(5), kcal: r.double(6),
                                    enmoMg: r.double(7), intensityBand: r.int(8), hrAvg: r.optDouble(9), hrMin: r.optDouble(10),
                                    hrMax: r.optDouble(11), hrv: r.optDouble(12), spo2: r.optDouble(13), skinTemp: r.optDouble(14),
                                    worn: r.int(15) != 0))
        }
        return out
    }

    public var windowCount: Int { (try? conn.scalar("SELECT COUNT(*) FROM windows")) ?? 0 }

    /// Local days with at least one stored window (uses today's UTC offset, close enough for display).
    public var dayCount: Int {
        let offset = calendar.timeZone.secondsFromGMT()
        return (try? conn.scalar("SELECT COUNT(DISTINCT (start + ?) / 86400) FROM windows", [.int(Int64(offset))])) ?? 0
    }

    public func summary(from: Date, to: Date) -> HealthSummary {
        var s = HealthSummary(start: from, end: to)
        let counted = "label NOT IN ('sleeping', 'not_worn')"
        // Same as FitnessLabel.isLocomotor with steps counted.
        let walking = "label IN ('walk', 'run') AND steps > 0"
        try? conn.query("""
            SELECT COUNT(*),
              SUM(CASE WHEN \(counted) THEN steps ELSE 0 END),
              SUM(CASE WHEN \(counted) THEN kcal ELSE 0 END),
              SUM(CASE WHEN \(counted) AND active THEN 0.5 ELSE 0 END),
              SUM(CASE WHEN \(counted) AND intensity_band >= 2 THEN 0.5 ELSE 0 END),
              SUM(CASE WHEN \(counted) AND intensity_band = 1 THEN 0.5 ELSE 0 END),
              SUM(CASE WHEN \(counted) AND intensity_band = 2 THEN 0.5 ELSE 0 END),
              SUM(CASE WHEN \(counted) AND intensity_band = 3 THEN 0.5 ELSE 0 END),
              MIN(hr_min), AVG(hr_avg), MAX(hr_max), AVG(hrv), AVG(spo2), AVG(skin_temp),
              SUM(CASE WHEN worn THEN 0.5 ELSE 0 END),
              SUM(CASE WHEN \(walking) THEN 0.5 ELSE 0 END),
              AVG(CASE WHEN \(walking) THEN cadence END)
            FROM windows WHERE start >= ? AND start < ?
            """, [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]) { r in
            s.windows = r.int(0)
            s.totals.steps = r.optInt(1) ?? 0
            s.totals.activeKcal = r.optDouble(2) ?? 0
            s.totals.activeMinutes = r.optDouble(3) ?? 0
            s.totals.mvpaMinutes = r.optDouble(4) ?? 0
            s.totals.lightMinutes = r.optDouble(5) ?? 0
            s.totals.mediumMinutes = r.optDouble(6) ?? 0
            s.totals.highMinutes = r.optDouble(7) ?? 0
            s.hrMin = r.optDouble(8); s.hrAvg = r.optDouble(9); s.hrMax = r.optDouble(10)
            s.hrv = r.optDouble(11); s.spo2 = r.optDouble(12); s.skinTemp = r.optDouble(13)
            s.wornMinutes = r.optDouble(14) ?? 0
            s.totals.walkingMinutes = r.optDouble(15) ?? 0
            s.totals.walkingCadence = r.optDouble(16)
        }
        return s
    }

    private func dayBounds(_ date: Date) -> (Date, Date) {
        let start = calendar.startOfDay(for: date)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400))
    }

    /// Activity totals for the local day containing `date`.
    public func totals(on date: Date) -> FitnessTotals {
        let (start, end) = dayBounds(date)
        return summary(from: start, to: end).totals
    }

    /// One summary per local day, from the day containing `from` through the day containing `to`.
    public func daily(from: Date, to: Date) -> [HealthSummary] {
        var out: [HealthSummary] = []
        var (start, end) = dayBounds(from)
        let last = calendar.startOfDay(for: to)
        while start <= last {
            out.append(summary(from: start, to: end))
            (start, end) = dayBounds(end)
        }
        return out
    }

    /// One summary per local day for the last `n` days, today included, oldest first.
    public func lastDays(_ n: Int, endingAt now: Date) -> [HealthSummary] {
        let from = calendar.date(byAdding: .day, value: -(max(1, n) - 1), to: calendar.startOfDay(for: now)) ?? now
        return daily(from: from, to: now)
    }

    /// One summary per hour of the local day containing `date` (23 or 25 on daylight-saving days).
    public func hourly(on date: Date) -> [HealthSummary] {
        let (dayStart, dayEnd) = dayBounds(date)
        var out: [HealthSummary] = []
        var start = dayStart
        while start < dayEnd {
            let end = min(calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3600), dayEnd)
            out.append(summary(from: start, to: end))
            start = end
        }
        return out
    }

    // MARK: baselines

    public func recordBaseline(_ b: Baseline, at now: Date = Date()) {
        try? conn.run("INSERT OR REPLACE INTO baselines (t, hr, hrv, skin_temp, established_at) VALUES (?, ?, ?, ?, ?)",
                      [.double(now.timeIntervalSince1970), .of(b.heartRate), .of(b.hrv), .of(b.skinTemp),
                       .of(b.establishedAt?.timeIntervalSince1970)])
    }

    /// The latest baseline, or nil if none was recorded within `maxAgeDays` of `now` (no limit when nil).
    public func latestBaseline(maxAgeDays: Double? = nil, now: Date = Date()) -> Baseline? {
        var b: Baseline?
        let cutoff = maxAgeDays.map { now.timeIntervalSince1970 - $0 * 86400 } ?? -.greatestFiniteMagnitude
        try? conn.query("SELECT hr, hrv, skin_temp, established_at FROM baselines WHERE t >= ? ORDER BY t DESC LIMIT 1", [.double(cutoff)]) { r in
            b = Baseline(heartRate: r.optDouble(0), hrv: r.optDouble(1), skinTemp: r.optDouble(2),
                         establishedAt: r.optDouble(3).map { Date(timeIntervalSince1970: $0) })
        }
        return b
    }

    // MARK: cards

    public func save(card: InsightCard) {
        guard let data = try? JSONEncoder().encode(card), let json = String(data: data, encoding: .utf8) else { return }
        try? conn.run("INSERT OR REPLACE INTO cards (id, t, kind, source, text, json) VALUES (?, ?, ?, ?, ?, ?)",
                      [.text(card.id.uuidString), .double(card.event.createdAt.timeIntervalSince1970),
                       .text(card.event.kind.rawValue), .text(card.source.rawValue), .text(card.text), .text(json)])
    }

    /// Newest first.
    public func recentCards(limit: Int) -> [InsightCard] {
        var out: [InsightCard] = []
        try? conn.query("SELECT json FROM cards ORDER BY t DESC LIMIT ?", [.int(Int64(limit))]) { r in
            if let s = r.text(0), let c = try? JSONDecoder().decode(InsightCard.self, from: Data(s.utf8)) { out.append(c) }
        }
        return out
    }

    public func deleteCards() { try? conn.run("DELETE FROM cards") }

    // MARK: housekeeping

    public var schemaVersion: Int { (try? conn.scalar("PRAGMA user_version")) ?? 0 }

    /// Bytes on disk, including the write-ahead log.
    public var fileSize: Int64 {
        guard let url else { return 0 }
        return ["", "-wal"].reduce(Int64(0)) { sum, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    /// Deletes every row by deleting the file, then reopens an empty database.
    public func wipe() {
        conn.close()
        if let url {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        if let fresh = try? Self.open(url) { conn = fresh }
    }
}
