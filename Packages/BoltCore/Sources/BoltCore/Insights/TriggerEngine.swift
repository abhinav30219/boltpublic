import Foundation

public enum TriggerKind: String, Codable, CaseIterable, Sendable {
    case exertion, recovery, elevatedAtRest, activityChange, skinTempShift, bandOff, safety, workoutFinished, fall, wave, moment

    public var title: String {
        switch self {
        case .exertion: return "Exertion"
        case .recovery: return "Recovery"
        case .elevatedAtRest: return "Up while still"
        case .activityChange: return "Activity"
        case .skinTempShift: return "Skin temperature"
        case .bandOff: return "Band contact"
        case .safety: return "Take a break"
        case .workoutFinished: return "Workout"
        case .fall: return "Possible fall"
        case .wave: return "Hi"
        case .moment: return "Moment marked"
        }
    }
    public var symbol: String {
        switch self {
        case .exertion: return "flame.fill"
        case .recovery: return "arrow.down.heart.fill"
        case .elevatedAtRest: return "waveform.path.ecg"
        case .activityChange: return "figure.walk"
        case .skinTempShift: return "thermometer.medium"
        case .bandOff: return "applewatch.slash"
        case .safety: return "exclamationmark.triangle.fill"
        case .workoutFinished: return "figure.run"
        case .fall: return "figure.fall"
        case .wave: return "hand.wave.fill"
        case .moment: return "bookmark.fill"
        }
    }
}

public struct InsightFact: Codable, Sendable, Equatable {
    public var label: String
    public var text: String          // exactly what the model sees, e.g. "68 bpm"
    public var number: Double?       // the number in `text`, for the number check
    public init(label: String, text: String, number: Double? = nil) {
        self.label = label; self.text = text; self.number = number
    }
    public static func num(_ label: String, _ v: Double, _ unit: String, digits: Int = 0) -> InsightFact {
        let s = Fmt.n(v, digits)
        return InsightFact(label: label, text: unit.isEmpty ? s : "\(s) \(unit)", number: Double(s))
    }
}

public struct InsightEvent: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var kind: TriggerKind
    public var createdAt: Date
    public var facts: [InsightFact]
    /// Text written by code, never by the model (safety messages). When set, skip the model.
    public var fixedText: String?
    public init(kind: TriggerKind, createdAt: Date, facts: [InsightFact], fixedText: String? = nil) {
        self.kind = kind; self.createdAt = createdAt; self.facts = facts; self.fixedText = fixedText
    }
}

public struct TriggerConfig: Codable, Sendable, Equatable {
    public var exertionRiseBpm: Double = 25
    public var exertionHoldSeconds: Double = 15
    public var recoveryWithinBpm: Double = 10
    public var restRiseBpm: Double = 20
    public var restHRVDropFraction: Double = 0.30
    public var restStillSeconds: Double = 60
    public var tempShiftC: Double = 0.5
    public var tempWindowSeconds: Double = 300
    public var bandOffSeconds: Double = 30
    public var safetyHRAtRest: Double = 150
    public var safetySpO2: Double = 90
    public var cooldownSeconds: Double = 20
    public var stillMotionG: Double = 0.03
    public init() {}
}

/// Plain rules over the live store. Code decides that something happened; Gemma only words it.
public final class TriggerEngine {
    public var config: TriggerConfig
    private var lastFired: [TriggerKind: Date] = [:]
    private var exertion: (start: Date, peakHR: Double, peakAt: Date, baseline: Double, activity: ActivityClass?)?
    private var lastExertionEnd: Date?
    private var bandOffActive = false
    private var safetyActive = false
    /// Time ranges of bouts already announced; a re-finalized bout may shift slightly, so overlap counts as fired.
    private var firedBouts: [(start: Double, end: Double)] = []

    public init(config: TriggerConfig = TriggerConfig()) { self.config = config }

    public func reset() {
        lastFired = [:]; exertion = nil; lastExertionEnd = nil; bandOffActive = false; safetyActive = false
        firedBouts = []
    }

    public var isInExertion: Bool { exertion != nil }

    private func ready(_ k: TriggerKind, _ now: Date, cooldown: Double? = nil) -> Bool {
        guard let t = lastFired[k] else { return true }
        return now.timeIntervalSince(t) >= (cooldown ?? config.cooldownSeconds)
    }

    private func fire(_ e: InsightEvent, into out: inout [InsightEvent]) {
        lastFired[e.kind] = e.createdAt
        out.append(e)
    }

    private func isStill(_ store: MetricsStore, seconds: Double, now: Date) -> Bool {
        if let a = store.currentActivity(now: now) { return a == .stationary && (store.motionLevel(seconds: seconds, now: now) ?? 0) < config.stillMotionG * 2 }
        if let m = store.motionLevel(seconds: seconds, now: now) { return m < config.stillMotionG }
        return false
    }

    private func isMoving(_ store: MetricsStore, now: Date) -> Bool {
        if let a = store.currentActivity(now: now), a.isActive { return true }
        return (store.motionLevel(seconds: 10, now: now) ?? 0) > config.stillMotionG * 2
    }

    /// Call about once a second. `activityChangedTo` is the smoother's output for this tick, if any.
    public func evaluate(_ store: MetricsStore, now: Date = Date(), activityChangedTo: ActivityClass? = nil, previousActivity: ActivityClass? = nil) -> [InsightEvent] {
        var out: [InsightEvent] = []

        // Band off: explicit off-wrist, or data arriving with no valid HR for a while.
        let noHR: Bool = {
            guard let latest = store.cardiac.last?.t, now.timeIntervalSince(latest) < 5 else { return false }
            guard let valid = store.lastValidHRAt else { return now.timeIntervalSince(store.sessionStart ?? now) > config.bandOffSeconds }
            return now.timeIntervalSince(valid) > config.bandOffSeconds
        }()
        // No valid heart rate alone doesn't mean off the wrist when the band itself reports contact
        // (the PPG often can't lock while you move).
        let off = store.wearState == .off || (noHR && store.wornFromWear != true)
        // A flickering signal used to re-fire this every few seconds; once per 5 minutes is plenty.
        if off && !bandOffActive && ready(.bandOff, now, cooldown: 300) {
            bandOffActive = true
            let since = store.lastValidHRAt.map { Int(now.timeIntervalSince($0)) } ?? Int(config.bandOffSeconds)
            fire(InsightEvent(kind: .bandOff, createdAt: now, facts: [
                .num("Seconds since last valid reading", Double(since), "s"),
                InsightFact(label: "Band status", text: store.wearState == .off ? "reported off the wrist" : "no reliable pulse signal"),
            ]), into: &out)
            exertion = nil
            return out
        }
        if !off { bandOffActive = false }
        if off { return out }

        // Workout finished: an Fitness bout of >= 5 min that a later window has ended, once per bout.
        if let latestEnd = store.fitness.latest?.end {
            for b in store.fitness.bouts where b.end < latestEnd - 0.5 && !firedBouts.contains(where: { $0.start < b.end && b.start < $0.end }) {
                firedBouts.append((b.start, b.end))
                let steps = store.fitness.timeline.windows(from: b.start, to: b.end).reduce(0) { $0 + $1.interval.metrics.steps }
                let kind = b.type == .run ? "running" : b.type == .cycle ? "cycling" : "walking"
                var facts: [InsightFact] = [InsightFact(label: "Workout type", text: kind), .num("Workout minutes", b.durationMin, "min")]
                if steps > 0 { facts.append(.num("Steps", Double(steps), "")) }
                if b.kcal >= 0.5 { facts.append(.num("Active calories", b.kcal, "kcal")) }
                if let h = b.averageHr { facts.append(.num("Average heart rate", h, "bpm")) }
                if let h = b.peakHr { facts.append(.num("Peak heart rate", h, "bpm")) }
                fire(InsightEvent(kind: .workoutFinished, createdAt: now, facts: facts), into: &out)
            }
        }

        guard let base = store.baseline.heartRate, store.baseline.isEstablished else { return out }
        let hr15 = store.stats(.heartRate, seconds: config.exertionHoldSeconds, now: now)
        let hr10 = store.stats(.heartRate, seconds: 10, now: now)

        // Safety lines come from code only.
        if let s = store.stats(.spo2, seconds: 15, now: now), s.count >= 3, s.max < config.safetySpO2, ready(.safety, now, cooldown: 120) {
            fire(InsightEvent(kind: .safety, createdAt: now, facts: [.num("SpO2", s.mean, "%")],
                              fixedText: "Blood oxygen reads \(Fmt.n(s.mean))%. Stop, sit down and breathe normally. If you feel short of breath, dizzy or have chest pain, call emergency services."), into: &out)
        }
        if let h = hr15, h.count >= 5, h.mean > config.safetyHRAtRest, isStill(store, seconds: 60, now: now) {
            if !safetyActive && ready(.safety, now, cooldown: 120) {
                safetyActive = true
                fire(InsightEvent(kind: .safety, createdAt: now, facts: [.num("Heart rate", h.mean, "bpm")],
                                  fixedText: "Heart rate is \(Fmt.n(h.mean)) bpm while you're still. Stop and rest. If you feel faint, have chest pain or it stays high, get medical help."), into: &out)
            }
        } else { safetyActive = false }

        // Exertion start.
        if exertion == nil, let h = hr15, h.count >= 5, h.min >= base + config.exertionRiseBpm * 0.8,
           h.mean >= base + config.exertionRiseBpm, isMoving(store, now: now), ready(.exertion, now) {
            let recent = store.points(.heartRate, since: now.addingTimeInterval(-180))
            let riseStart = recent.last(where: { $0.value <= base + 10 })?.t ?? recent.first?.t ?? now
            let riseSeconds = max(1, now.timeIntervalSince(riseStart))
            let act = store.currentActivity(now: now)
            exertion = (start: riseStart, peakHR: h.latest, peakAt: now, baseline: base, activity: act)
            var facts: [InsightFact] = [
                .num("Resting heart rate", base, "bpm"),
                .num("Heart rate now", h.latest, "bpm"),
                .num("Seconds to rise", riseSeconds, "s"),
            ]
            // The activity model looks at the last 30 s, so it can still say "still" as effort starts.
            // Exertion already requires movement, so never pass a stale "still" to the card.
            facts.append(InsightFact(label: "Activity", text: (act?.isActive == true ? act!.label.lowercased() : "moving")))
            fire(InsightEvent(kind: .exertion, createdAt: now, facts: facts), into: &out)
        }

        // Track peak, then recovery.
        if var ex = exertion {
            if let h = hr10, h.max > ex.peakHR { ex.peakHR = h.max; ex.peakAt = now }
            exertion = ex
            if let h = hr10, h.count >= 3, h.mean <= ex.baseline + config.recoveryWithinBpm {
                let recoverySeconds = max(1, now.timeIntervalSince(ex.peakAt))
                let durationSeconds = max(1, ex.peakAt.timeIntervalSince(ex.start))
                fire(InsightEvent(kind: .recovery, createdAt: now, facts: [
                    .num("Peak heart rate", ex.peakHR, "bpm"),
                    .num("Heart rate now", h.latest, "bpm"),
                    .num("Seconds from peak to near resting", recoverySeconds, "s"),
                    .num("Seconds of effort", durationSeconds, "s"),
                ]), into: &out)
                exertion = nil
                lastExertionEnd = now
            }
        }

        // Elevated while still (not right after exercise).
        let afterExercise = lastExertionEnd.map { now.timeIntervalSince($0) < 180 } ?? false
        if exertion == nil, !afterExercise, isStill(store, seconds: config.restStillSeconds, now: now),
           let h = store.stats(.heartRate, seconds: 30, now: now), h.count >= 10, ready(.elevatedAtRest, now, cooldown: 180) {
            let hrv = store.stats(.hrv, seconds: 60, now: now)
            let hrvDrop: Double? = {
                guard let b = store.baseline.hrv, b > 0, let v = hrv?.mean else { return nil }
                return (b - v) / b
            }()
            let riseOK = h.mean >= base + config.restRiseBpm
            let hrvOK = hrvDrop.map { $0 >= config.restHRVDropFraction } ?? (h.mean >= base + config.restRiseBpm + 5)
            if riseOK && hrvOK {
                var facts: [InsightFact] = [
                    .num("Resting heart rate", base, "bpm"),
                    .num("Heart rate now", h.mean, "bpm"),
                    .num("Minutes still", config.restStillSeconds / 60, "min"),
                ]
                if let b = store.baseline.hrv, let v = hrv?.mean {
                    facts.append(.num("Usual HRV", b, "ms"))
                    facts.append(.num("HRV now", v, "ms"))
                }
                fire(InsightEvent(kind: .elevatedAtRest, createdAt: now, facts: facts), into: &out)
            }
        }

        // Activity change (from the smoothed activity model).
        if let to = activityChangedTo, ready(.activityChange, now) {
            var facts: [InsightFact] = [InsightFact(label: "New activity", text: to.label.lowercased())]
            if let from = previousActivity { facts.insert(InsightFact(label: "Previous activity", text: from.label.lowercased()), at: 0) }
            if let h = hr10 { facts.append(.num("Heart rate now", h.latest, "bpm")) }
            fire(InsightEvent(kind: .activityChange, createdAt: now, facts: facts), into: &out)
        }

        // Skin temperature shift over ~5 minutes.
        if ready(.skinTempShift, now, cooldown: 300) {
            let w = config.tempWindowSeconds
            let old = store.skinTemp.filter { $0.t >= now.addingTimeInterval(-w) && $0.t < now.addingTimeInterval(-w + 30) }.map { $0.value }
            let cur = store.skinTemp.filter { $0.t >= now.addingTimeInterval(-30) }.map { $0.value }
            if let a = Stats.mean(old), let b = Stats.mean(cur), abs(b - a) >= config.tempShiftC {
                var facts: [InsightFact] = [
                    .num("Skin temperature before", a, "°C", digits: 1),
                    .num("Skin temperature now", b, "°C", digits: 1),
                    .num("Minutes", w / 60, "min"),
                ]
                if let act = store.currentActivity(now: now) { facts.append(InsightFact(label: "Activity", text: act.label.lowercased())) }
                fire(InsightEvent(kind: .skinTempShift, createdAt: now, facts: facts), into: &out)
            }
        }
        return out
    }
}
