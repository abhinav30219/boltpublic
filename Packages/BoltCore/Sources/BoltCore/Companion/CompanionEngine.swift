import Foundation

/// Maps live health inputs to the companion's motion, mood, blush, overlays and one-shot events.
/// Pure logic: no clocks of its own, the caller passes `now`.
public final class CompanionEngine {
    public var tuning: CompanionTuning

    // Session state (cleared by resetSession).
    private var motion: CompanionMotion?
    private var motionCandidate: CompanionMotion?
    private var motionCandidateSince = Date.distantPast
    private var mood: CompanionMood?
    private var moodSince = Date.distantPast
    private var lastRecoveryAt: Date?
    private var lastElevatedAt: Date?
    private var lastCelebrationAt: Date?
    private var wasSleeping = false
    private var wasFallAlert = false

    // Per-day event log (survives resetSession).
    private var logDay: Date?
    private var highestMilestone = 0
    private var goalFired = false
    /// False until the first step update after init/resetSession; that update seeds the log without emitting.
    private var stepsSeeded = false

    public init(tuning: CompanionTuning = .init()) { self.tuning = tuning }

    /// Tanaka estimate of maximum heart rate.
    public static func estimatedMaxHR(age: Double) -> Double { 208 - 0.7 * age }

    /// Clears holds and timers; keeps the per-day event log so milestones do not repeat.
    public func resetSession() {
        motion = nil; motionCandidate = nil; motionCandidateSince = .distantPast
        mood = nil; moodSince = .distantPast
        lastRecoveryAt = nil; lastElevatedAt = nil; lastCelebrationAt = nil
        wasSleeping = false; wasFallAlert = false
        stepsSeeded = false
    }

    public func update(_ input: CompanionInput, now: Date) -> (state: CompanionState, events: [CompanionEvent]) {
        var events: [CompanionEvent] = []

        // Motion with hold.
        let candidate = Self.candidateMotion(input)
        let adopted = resolveMotion(candidate, now: now)

        let sleeping = adopted == .sleep
        if sleeping && !wasSleeping { events.append(.bandOff) }
        wasSleeping = sleeping

        if input.triggers.contains(.recovery) {
            events.append(.recovery)
            lastRecoveryAt = now
        }
        if input.triggers.contains(.elevatedAtRest) { lastElevatedAt = now }
        if input.fallAlertActive && !wasFallAlert { events.append(.fallSuspected) }
        wasFallAlert = input.fallAlertActive
        if input.fallResolved { events.append(.fallResolved) }

        let stepEvents = dailyStepEvents(steps: input.steps, now: now)
        if !stepEvents.isEmpty { lastCelebrationAt = now }
        events += stepEvents

        // Heart rate derived values.
        let maxHR = Self.estimatedMaxHR(age: input.age ?? Double(tuning.defaultAge))
        var zone = HRZone.baseline
        var blush = 0.0
        if let hr = input.hr, let base = input.baselineHR {
            if hr >= tuning.steamFractionOfMax * maxHR { zone = .veryHigh }
            else if hr >= tuning.highFractionOfMax * maxHR { zone = .high }
            else if hr >= base + tuning.elevatedAboveBaselineBpm { zone = .elevated }
            else if hr < base - tuning.belowBaselineBpm { zone = .below }
            let start = base + tuning.blushStartAboveBaselineBpm
            let span = tuning.blushFullFractionOfMax * maxHR - start
            if span > 0 {
                let x = min(1, max(0, (hr - start) / span))
                blush = x * x * (3 - 2 * x)
            } else if hr >= start {
                blush = 1
            }
        }

        var overlays = Set<CompanionOverlay>()
        if zone == .veryHigh { overlays.insert(.steam) }
        if let t = input.skinTemp, let base = input.baselineSkinTemp {
            if t <= base - tuning.tempShiftC { overlays.insert(.frost) }
            if t >= base + tuning.tempShiftC { overlays.insert(.sweat) }
        }
        if sleeping { overlays.insert(.zzz) }

        var state = CompanionState()
        state.motion = adopted
        state.cadence = input.cadence
        state.mood = resolveMood(input, motion: adopted, now: now)
        state.blush = blush
        state.overlays = overlays
        state.hrZone = zone
        state.stepsToday = input.steps
        state.bandWorn = input.worn
        state.userWalking = adopted == .walk || adopted == .trot
        state.fallAlertActive = input.fallAlertActive
        return (state, events)
    }

    // MARK: motion

    private static func candidateMotion(_ input: CompanionInput) -> CompanionMotion {
        guard input.hasData && input.worn else { return .sleep }
        switch input.activity {
        case .walk, .stairs: return .walk
        case .run, .cycle: return .trot
        default: return .idle
        }
    }

    private func resolveMotion(_ candidate: CompanionMotion, now: Date) -> CompanionMotion {
        if candidate != motionCandidate {
            motionCandidate = candidate
            motionCandidateSince = now
        }
        guard let current = motion else {
            motion = candidate      // first tick: nothing to hold against
            return candidate
        }
        if candidate == current { return current }
        if candidate == .sleep || now.timeIntervalSince(motionCandidateSince) >= tuning.motionHoldSeconds {
            motion = candidate
            return candidate
        }
        return current
    }

    // MARK: mood

    private func resolveMood(_ input: CompanionInput, motion: CompanionMotion, now: Date) -> CompanionMood {
        let (candidate, immediate) = candidateMood(input, motion: motion, now: now)
        guard let current = mood else {
            mood = candidate; moodSince = now
            return candidate
        }
        if candidate == current { return current }
        // Leaving sleeping needs no hold once the motion has woken up.
        let wakes = current == .sleeping && motion != .sleep
        if immediate || wakes || now.timeIntervalSince(moodSince) >= tuning.moodHoldSeconds {
            mood = candidate; moodSince = now
            return candidate
        }
        return current
    }

    private func candidateMood(_ input: CompanionInput, motion: CompanionMotion, now: Date) -> (CompanionMood, immediate: Bool) {
        // A fall alert outranks sleeping: with no data source the motion is .sleep, yet the fall must still show.
        if input.fallAlertActive { return (.concerned, true) }
        if motion == .sleep { return (.sleeping, true) }
        if input.calibrating { return (.scanning, false) }
        if let e = lastElevatedAt, now.timeIntervalSince(e) < tuning.concernedSeconds { return (.concerned, false) }
        if let r = lastRecoveryAt, now.timeIntervalSince(r) < tuning.relievedSeconds { return (.relieved, false) }
        if motion == .trot { return (.determined, false) }
        if let c = lastCelebrationAt, now.timeIntervalSince(c) < tuning.happySeconds { return (.happy, false) }
        if let hrv = input.hrv, let base = input.baselineHRV {
            if hrv >= base * (1 + tuning.calmHRVAboveBaseline) { return (.calm, false) }
            if hrv <= base * (1 - tuning.tiredHRVBelowBaseline) { return (.tired, false) }
        }
        return (.neutral, false)
    }

    // MARK: steps

    private func dailyStepEvents(steps: Int, now: Date) -> [CompanionEvent] {
        let day = Calendar.current.startOfDay(for: now)
        if logDay != day {
            logDay = day
            highestMilestone = 0
            goalFired = false
        }
        var out: [CompanionEvent] = []
        let m = tuning.milestoneSteps > 0 ? steps / tuning.milestoneSteps : 0
        if !stepsSeeded {
            // First update after launch/reset: steps may be a carried daily total, not new walking.
            stepsSeeded = true
            highestMilestone = max(highestMilestone, m)
            if steps >= tuning.dailyStepGoal { goalFired = true }
            return out
        }
        if m > highestMilestone {
            highestMilestone = m
            out.append(.stepMilestone)
        }
        if !goalFired && steps >= tuning.dailyStepGoal {
            goalFired = true
            out.append(.goalReached)
        }
        return out
    }
}
