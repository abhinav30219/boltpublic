import Foundation

/// Personal resting reference: median of the first `calibrationSeconds` of valid, still data,
/// then slowly updated only while the wearer is still.
public struct Baseline: Codable, Sendable, Equatable {
    public var heartRate: Double?
    public var hrv: Double?
    public var skinTemp: Double?
    public var establishedAt: Date?
    public var isEstablished: Bool { establishedAt != nil && heartRate != nil }
    public init(heartRate: Double? = nil, hrv: Double? = nil, skinTemp: Double? = nil, establishedAt: Date? = nil) {
        self.heartRate = heartRate; self.hrv = hrv; self.skinTemp = skinTemp; self.establishedAt = establishedAt
    }
}

/// Why heart-rate readings in a span were kept or dropped, for the per-window debug log.
public struct HRDropCounts: Equatable, Sendable {
    public var readings = 0
    public var kept = 0
    /// Below `minValidPermille`, whatever the band sent.
    public var lowConfidence = 0
    /// Confident, but the band sent no heart rate.
    public var noValueFromBand = 0
    /// Confident, but outside 30...220 bpm.
    public var outOfRange = 0
    public var validPermilleMin: Int?
    public var validPermilleMean: Double?
    public var validPermilleMax: Int?
    /// Firmware reason code -> count.
    public var hrReasons: [Int: Int] = [:]
    public var hrvReasons: [Int: Int] = [:]
    public init() {}
}

/// All live data, kept in time-bounded buffers. Not thread-safe: use it from one actor (the app's main actor).
public final class MetricsStore {
    public private(set) var cardiac: [CardiacPoint] = []
    public private(set) var skinTemp: [ScalarPoint] = []
    private var lastTempAAt: Date?
    public private(set) var accel: [AccelPoint] = []
    public private(set) var activity: [ActivityPoint] = []
    public private(set) var wearState: WearState = .unknown
    public private(set) var wearUpdatedAt: Date?
    public private(set) var lastValidHRAt: Date?
    public private(set) var sessionStart: Date?
    public var baseline = Baseline()
    /// Activity windows, totals and bouts, published by the app from the Core Motion activity engine.
    public var fitness = FitnessState()
    /// Seconds of data kept for each stream.
    public var cardiacRetention: TimeInterval = 60 * 60
    public var accelRetention: TimeInterval = 120
    public var calibrationSeconds: TimeInterval = 30
    /// Minimum firmware confidence for a heart-rate reading to count.
    public var minValidPermille = 300

    public init() {}

    public func reset() {
        cardiac = []; skinTemp = []; accel = []; activity = []
        wearState = .unknown; wearUpdatedAt = nil; lastValidHRAt = nil; sessionStart = nil
        baseline = Baseline()
        fitness = FitnessState()
    }

    public func resetBaseline(now: Date = Date()) {
        baseline = Baseline()
        sessionStart = now
    }

    // MARK: ingest

    public func ingest(_ input: LiveInput, at now: Date = Date()) {
        if sessionStart == nil { sessionStart = now }
        switch input {
        case .cardiac(let r):
            let valid = r.validPermille >= minValidPermille
            let hr = valid ? r.hrBpm.flatMap { (30...220).contains($0) ? $0 : nil } : nil
            let rmssd = valid ? r.rmssdMs.flatMap { (3...300).contains($0) ? $0 : nil } : nil
            let spo2 = r.spo2Pct.flatMap { (70...100).contains($0) ? $0 : nil }
            cardiac.append(CardiacPoint(t: now, hr: hr, rmssd: rmssd, spo2: spo2, validPermille: r.validPermille,
                                        rawHR: r.hrBpm))
            if hr != nil { lastValidHRAt = now }
            trim(&cardiac, keep: cardiacRetention, now: now) { $0.t }
        case .imu(let samples):
            guard !samples.isEmpty else { return }
            // Phone receive time for the newest sample; earlier samples are spaced by their device times.
            let lastT = samples.last!.tMs
            for s in samples {
                let t = now.addingTimeInterval((s.tMs - lastT) / 1000)
                let g = IMUScale.standardGravity
                accel.append(AccelPoint(t: t, x: s.axMS2 / g, y: s.ayMS2 / g, z: s.azMS2 / g))
            }
            trim(&accel, keep: accelRetention, now: now) { $0.t }
        case .temperature(let s):
            // Sensor A is the skin sensor; fall back to B only when A has gone quiet for a minute.
            if s.sensor == .a { lastTempAAt = now }
            let useB = s.sensor == .b && (lastTempAAt.map { now.timeIntervalSince($0) > 60 } ?? true)
            guard s.sensor == .a || useB, (20...45).contains(s.celsius) else { return }
            skinTemp.append(ScalarPoint(t: now, value: s.celsius))
            trim(&skinTemp, keep: cardiacRetention, now: now) { $0.t }
        case .wear(let w):
            wearState = w.state
            wornFromWear = w.isWorn
            wearUpdatedAt = now
        }
        updateBaseline(now: now)
    }

    public func ingest(activity point: ActivityPoint) {
        activity.append(point)
        trim(&activity, keep: cardiacRetention, now: point.t) { $0.t }
    }

    private func trim<T>(_ a: inout [T], keep: TimeInterval, now: Date, time: (T) -> Date) {
        let cutoff = now.addingTimeInterval(-keep)
        if let i = a.firstIndex(where: { time($0) >= cutoff }), i > 0 { a.removeFirst(i) }
        else if let last = a.last, time(last) < cutoff { a.removeAll() }
    }

    // MARK: baseline

    private func updateBaseline(now: Date) {
        guard let start = sessionStart else { return }
        if !baseline.isEstablished {
            guard now.timeIntervalSince(start) >= calibrationSeconds else { return }
            let pts = cardiac.filter { $0.t >= start }
            let hrs = pts.compactMap { $0.hr }
            guard hrs.count >= 10 else { return }
            baseline.heartRate = Stats.median(hrs)
            baseline.hrv = Stats.median(pts.compactMap { $0.rmssd })
            baseline.skinTemp = Stats.median(skinTemp.filter { $0.t >= start }.map { $0.value })
            baseline.establishedAt = now
        } else if currentActivity(now: now) == .stationary, let hr = latest(.heartRate, maxAge: 10, now: now) {
            // Slow drift toward resting values while still (time constant ~10 min at 1 Hz).
            let a = 1.0 / 600
            if let b = baseline.heartRate, hr < b + 15 { baseline.heartRate = b + a * (hr - b) }
            if let r = latest(.hrv, maxAge: 10, now: now), let b = baseline.hrv { baseline.hrv = b + a * (r - b) }
            if let t = latest(.skinTemp, maxAge: 60, now: now), let b = baseline.skinTemp { baseline.skinTemp = b + a * (t - b) }
        }
    }

    public var calibrationProgress: Double {
        guard let start = sessionStart else { return 0 }
        if baseline.isEstablished { return 1 }
        let elapsed = (cardiac.last?.t ?? start).timeIntervalSince(start)
        return min(0.99, max(0, elapsed / calibrationSeconds))
    }

    // MARK: queries

    public func points(_ metric: Metric, since: Date) -> [ScalarPoint] {
        switch metric {
        case .heartRate: return cardiac.filter { $0.t >= since }.compactMap { p in p.hr.map { ScalarPoint(t: p.t, value: $0) } }
        case .hrv: return cardiac.filter { $0.t >= since }.compactMap { p in p.rmssd.map { ScalarPoint(t: p.t, value: $0) } }
        case .spo2: return cardiac.filter { $0.t >= since }.compactMap { p in p.spo2.map { ScalarPoint(t: p.t, value: $0) } }
        case .skinTemp: return skinTemp.filter { $0.t >= since }
        case .motion: return motionSeries(since: since)
        }
    }

    public func latest(_ metric: Metric, maxAge: TimeInterval, now: Date = Date()) -> Double? {
        points(metric, since: now.addingTimeInterval(-maxAge)).last?.value
    }

    public func stats(_ metric: Metric, seconds: TimeInterval, now: Date = Date()) -> WindowStats? {
        let pts = points(metric, since: now.addingTimeInterval(-seconds))
        guard let last = pts.last else { return nil }
        let vs = pts.map { $0.value }
        return WindowStats(count: vs.count, mean: Stats.mean(vs)!, min: vs.min()!, max: vs.max()!,
                           latest: last.value, slopePerMinute: Stats.slopePerMinute(pts))
    }

    public func hrDropCounts(from: Date, to: Date) -> HRDropCounts {
        var c = HRDropCounts()
        let pts = cardiac.filter { $0.t >= from && $0.t < to }
        guard !pts.isEmpty else { return c }
        for p in pts {
            c.readings += 1
            if p.hr != nil { c.kept += 1 }
            else if p.validPermille < minValidPermille { c.lowConfidence += 1 }
            else if p.rawHR == nil { c.noValueFromBand += 1 }
            else { c.outOfRange += 1 }
            if let r = p.hrReason { c.hrReasons[r, default: 0] += 1 }
            if let r = p.hrvReason { c.hrvReasons[r, default: 0] += 1 }
        }
        let v = pts.map { $0.validPermille }
        c.validPermilleMin = v.min(); c.validPermilleMax = v.max()
        c.validPermilleMean = Double(v.reduce(0, +)) / Double(v.count)
        return c
    }

    /// Stats over `[from, to)`, for a closed window rather than one ending now.
    public func stats(_ metric: Metric, from: Date, to: Date) -> WindowStats? {
        let pts = points(metric, since: from).filter { $0.t < to }
        guard let last = pts.last else { return nil }
        let vs = pts.map { $0.value }
        return WindowStats(count: vs.count, mean: Stats.mean(vs)!, min: vs.min()!, max: vs.max()!,
                           latest: last.value, slopePerMinute: Stats.slopePerMinute(pts))
    }

    /// Up to `maxPoints` evenly spaced bucket means for sparklines and tool output.
    public func series(_ metric: Metric, seconds: TimeInterval, maxPoints: Int, now: Date = Date()) -> [ScalarPoint] {
        let since = now.addingTimeInterval(-seconds)
        let pts = points(metric, since: since)
        guard pts.count > maxPoints, maxPoints > 0 else { return pts }
        let bucket = seconds / Double(maxPoints)
        var out: [ScalarPoint] = []
        for i in 0..<maxPoints {
            let a = since.addingTimeInterval(Double(i) * bucket), b = a.addingTimeInterval(bucket)
            let vs = pts.filter { $0.t >= a && $0.t < b }.map { $0.value }
            if let m = Stats.mean(vs) { out.append(ScalarPoint(t: a.addingTimeInterval(bucket / 2), value: m)) }
        }
        return out
    }

    /// Standard deviation of acceleration magnitude (g) per second.
    private func motionSeries(since: Date) -> [ScalarPoint] {
        let pts = accel.filter { $0.t >= since }
        guard let first = pts.first else { return [] }
        var out: [ScalarPoint] = []
        var bucket: [Double] = []
        var bucketStart = first.t
        for p in pts {
            if p.t.timeIntervalSince(bucketStart) >= 1 {
                if let s = Stats.std(bucket) { out.append(ScalarPoint(t: bucketStart, value: s)) }
                bucket = []; bucketStart = p.t
            }
            bucket.append(p.magnitude)
        }
        if let s = Stats.std(bucket) { out.append(ScalarPoint(t: bucketStart, value: s)) }
        return out
    }

    /// Motion level over the last `seconds`: std of accel magnitude in g.
    public func motionLevel(seconds: TimeInterval, now: Date = Date()) -> Double? {
        Stats.std(accel.filter { $0.t >= now.addingTimeInterval(-seconds) }.map { $0.magnitude })
    }

    /// Accelerometer resampled to `rateHz` for the last `seconds`, channels-first [x, y, z], in g.
    /// Returns nil until the window is mostly covered.
    public func accelWindow(seconds: TimeInterval = 30, rateHz: Double = 30, now: Date = Date()) -> [[Float]]? {
        let n = Int(seconds * rateHz)
        let start = now.addingTimeInterval(-seconds)
        let pts = accel.filter { $0.t >= start.addingTimeInterval(-1) }
        guard pts.count >= n / 2, let first = pts.first, first.t <= start.addingTimeInterval(seconds * 0.25) else { return nil }
        var xs = [Float](repeating: 0, count: n), ys = xs, zs = xs
        var j = 0
        for i in 0..<n {
            let t = start.addingTimeInterval(Double(i) / rateHz)
            while j + 1 < pts.count && pts[j + 1].t <= t { j += 1 }
            let p = pts[j]
            xs[i] = Float(p.x); ys[i] = Float(p.y); zs[i] = Float(p.z)
        }
        return [xs, ys, zs]
    }

    public func currentActivity(now: Date = Date()) -> ActivityClass? {
        guard let a = activity.last, now.timeIntervalSince(a.t) < 20 else { return nil }
        return a.activity
    }

    public var isWorn: Bool {
        if wearState == .off { return false }
        if wornFromWear == true { return true }
        if let t = lastValidHRAt, let latest = cardiac.last?.t { return latest.timeIntervalSince(t) < 30 }
        return wearState == .on
    }

    /// Wear as the band reports it (`WearStatusSample.isWorn`): nil when unknown.
    public private(set) var wornFromWear: Bool?

    /// When anything (cardiac, motion or temperature) last arrived from the band.
    public var lastDataAt: Date? { [cardiac.last?.t, accel.last?.t, skinTemp.last?.t].compactMap { $0 }.max() }

    /// Activity segments (merged consecutive same-class points) within the last `seconds`.
    public func activityTimeline(seconds: TimeInterval, now: Date = Date()) -> [(start: Date, end: Date, activity: ActivityClass)] {
        let pts = activity.filter { $0.t >= now.addingTimeInterval(-seconds) }
        var out: [(start: Date, end: Date, activity: ActivityClass)] = []
        for p in pts {
            if let last = out.last, last.activity.label == p.activity.label, p.t.timeIntervalSince(last.end) < 30 {
                out[out.count - 1].end = p.t
            } else {
                out.append((start: p.t, end: p.t, activity: p.activity))
            }
        }
        return out
    }
}
