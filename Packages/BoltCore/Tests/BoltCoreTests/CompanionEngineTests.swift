import XCTest
@testable import BoltCore

final class CompanionEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private func input(hr: Double? = nil, hrv: Double? = nil, skinTemp: Double? = nil,
                       activity: ActivityClass? = nil, hasData: Bool = true, worn: Bool = true,
                       calibrating: Bool = false, baselineHR: Double? = 65, steps: Int = 0,
                       cadence: Double = 0, triggers: [TriggerKind] = [],
                       fallAlertActive: Bool = false, fallResolved: Bool = false) -> CompanionInput {
        CompanionInput(hr: hr, hrv: hrv, skinTemp: skinTemp, baselineHR: baselineHR, baselineHRV: 40, baselineSkinTemp: 33,
                       activity: activity, hasData: hasData, worn: worn, calibrating: calibrating, age: 70,
                       steps: steps, cadence: cadence, triggers: triggers,
                       fallAlertActive: fallAlertActive, fallResolved: fallResolved)
    }

    /// An engine already settled into neutral/idle at t0.
    private func settledEngine() -> CompanionEngine {
        let e = CompanionEngine()
        _ = e.update(input(), now: at(0))
        return e
    }

    func testNoDataSleepsWithZzzAndFiresBandOffOnce() {
        let e = CompanionEngine()
        let a = e.update(input(hasData: false), now: at(0))
        XCTAssertEqual(a.state.motion, .sleep)
        XCTAssertEqual(a.state.mood, .sleeping)
        XCTAssertEqual(a.state.overlays, [.zzz])
        XCTAssertEqual(a.events, [.bandOff])
        XCTAssertEqual(e.update(input(hasData: false), now: at(1)).events, [])
    }

    func testWalkNeedsThreeSecondsHold() {
        let e = settledEngine()
        XCTAssertEqual(e.update(input(activity: .walk), now: at(1)).state.motion, .idle)
        XCTAssertEqual(e.update(input(activity: .walk), now: at(2)).state.motion, .idle)
        let s = e.update(input(activity: .walk), now: at(4)).state
        XCTAssertEqual(s.motion, .walk)
        XCTAssertTrue(s.userWalking)
    }

    func testRunIsTrotAndDetermined() {
        let e = CompanionEngine()
        _ = e.update(input(), now: at(-10))     // settled long enough that no hold is pending
        _ = e.update(input(activity: .run), now: at(1))
        let s = e.update(input(activity: .run), now: at(5)).state
        XCTAssertEqual(s.motion, .trot)
        XCTAssertEqual(s.mood, .determined)
    }

    func testBlushRampsWithHR() {
        let e = settledEngine()
        XCTAssertEqual(e.update(input(hr: 70), now: at(1)).state.blush, 0)
        let full = 0.85 * (208 - 0.7 * 70)
        let top = e.update(input(hr: full), now: at(2)).state
        XCTAssertEqual(top.blush, 1, accuracy: 1e-9)
        XCTAssertEqual(top.hrZone, .veryHigh)
        XCTAssertTrue(top.overlays.contains(.steam))
        let mid = e.update(input(hr: 100), now: at(3)).state.blush
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, 1)
    }

    func testCalibratingWithoutBaselineIsScanning() {
        let e = CompanionEngine()
        let s = e.update(input(hr: 90, calibrating: true, baselineHR: nil), now: at(0)).state
        XCTAssertEqual(s.mood, .scanning)
        XCTAssertEqual(s.blush, 0)
        XCTAssertEqual(s.hrZone, .baseline)
    }

    func testRecoveryTriggerGivesRelievedAndEvent() {
        let e = settledEngine()
        let r = e.update(input(triggers: [.recovery]), now: at(10))
        XCTAssertEqual(r.events, [.recovery])
        XCTAssertEqual(r.state.mood, .relieved)
        XCTAssertNotEqual(e.update(input(), now: at(31)).state.mood, .relieved)
    }

    func testElevatedAtRestIsConcerned() {
        let e = settledEngine()
        XCTAssertEqual(e.update(input(triggers: [.elevatedAtRest]), now: at(10)).state.mood, .concerned)
    }

    func testHRVCalmAndTired() {
        let c = CompanionEngine()
        XCTAssertEqual(c.update(input(hrv: 47), now: at(0)).state.mood, .calm)
        let t = settledEngine()
        XCTAssertEqual(t.update(input(hrv: 31), now: at(1)).state.mood, .neutral)
        XCTAssertEqual(t.update(input(hrv: 31), now: at(9)).state.mood, .tired)
    }

    func testSafetyTriggerNeverChangesMood() {
        let e = settledEngine()
        let r = e.update(input(triggers: [.safety, .exertion, .activityChange, .skinTempShift, .bandOff, .workoutFinished]), now: at(20))
        XCTAssertEqual(r.state.mood, .neutral)
        XCTAssertEqual(r.events, [])
    }

    func testMoodHoldsEightSeconds() {
        let e = CompanionEngine()
        XCTAssertEqual(e.update(input(hrv: 47), now: at(0)).state.mood, .calm)
        XCTAssertEqual(e.update(input(hrv: 31), now: at(3)).state.mood, .calm)
        XCTAssertEqual(e.update(input(hrv: 31), now: at(9)).state.mood, .tired)
    }

    func testFallAlertOverridesImmediately() {
        let e = settledEngine()
        let a = e.update(input(fallAlertActive: true), now: at(1))
        XCTAssertEqual(a.state.mood, .concerned)
        XCTAssertTrue(a.state.fallAlertActive)
        XCTAssertEqual(a.events, [.fallSuspected])
        let b = e.update(input(fallAlertActive: false, fallResolved: true), now: at(2))
        XCTAssertEqual(b.events, [.fallResolved])
    }

    func testFallAlertOutranksSleeping() {
        let e = CompanionEngine()
        let r = e.update(input(hasData: false, fallAlertActive: true), now: at(0))
        XCTAssertEqual(r.state.mood, .concerned)
        XCTAssertTrue(r.events.contains(.fallSuspected))
    }

    func testStepJumpFiresOneMilestone() {
        let e = settledEngine()
        XCTAssertEqual(e.update(input(steps: 900), now: at(1)).events, [])
        XCTAssertEqual(e.update(input(steps: 3100), now: at(2)).events, [.stepMilestone])
        XCTAssertEqual(e.update(input(steps: 2500), now: at(3)).events, [])
        XCTAssertEqual(e.update(input(steps: 4000), now: at(4)).events, [.stepMilestone])
    }

    func testGoalReachedOncePerDay() {
        let e = CompanionEngine()
        _ = e.update(input(steps: 7990), now: at(0))
        XCTAssertTrue(e.update(input(steps: 8010), now: at(1)).events.contains(.goalReached))
        XCTAssertFalse(e.update(input(steps: 8500), now: at(2)).events.contains(.goalReached))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: t0)!
        XCTAssertTrue(e.update(input(steps: 8010), now: tomorrow).events.contains(.goalReached))
    }

    func testLaunchWithCarriedStepsEmitsNothingThenRealCrossingFires() {
        let e = CompanionEngine()
        XCTAssertEqual(e.update(input(steps: 6000), now: at(0)).events, [])
        XCTAssertEqual(e.update(input(steps: 6000), now: at(1)).events, [])
        XCTAssertEqual(e.update(input(steps: 7000), now: at(2)).events, [.stepMilestone])
    }

    func testLaunchPastGoalDoesNotEmitGoalReached() {
        let e = CompanionEngine()
        XCTAssertEqual(e.update(input(steps: 9500), now: at(0)).events, [])
        XCTAssertEqual(e.update(input(steps: 9600), now: at(1)).events, [])
        XCTAssertEqual(e.update(input(steps: 10_000), now: at(2)).events, [.stepMilestone])
    }

    func testNewDayAfterSeededLaunchResets() {
        let e = CompanionEngine()
        _ = e.update(input(steps: 9500), now: at(0))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: t0)!
        let r = e.update(input(steps: 8010), now: tomorrow)
        XCTAssertTrue(r.events.contains(.goalReached))
        XCTAssertTrue(r.events.contains(.stepMilestone))
    }

    func testResetSessionReseedsWithoutEmittingCarriedSteps() {
        let e = CompanionEngine()
        _ = e.update(input(steps: 500), now: at(0))
        e.resetSession()
        XCTAssertEqual(e.update(input(steps: 6000), now: at(1)).events, [])
        XCTAssertEqual(e.update(input(steps: 7000), now: at(2)).events, [.stepMilestone])
    }

    func testResetSessionKeepsDailyEvents() {
        let e = settledEngine()
        XCTAssertEqual(e.update(input(steps: 1200), now: at(1)).events, [.stepMilestone])
        e.resetSession()
        XCTAssertEqual(e.update(input(steps: 0), now: at(2)).events, [])
        XCTAssertEqual(e.update(input(steps: 1200), now: at(3)).events, [])
    }

    func testWarmAndCoolOverlays() {
        let e = settledEngine()
        XCTAssertTrue(e.update(input(skinTemp: 33.6), now: at(1)).state.overlays.contains(.sweat))
        XCTAssertTrue(e.update(input(skinTemp: 32.4), now: at(2)).state.overlays.contains(.frost))
    }

    func testElevatedAtRestDuringMoodHoldShowsAfterHold() {
        let e = CompanionEngine()
        XCTAssertEqual(e.update(input(hrv: 47), now: at(0)).state.mood, .calm)
        XCTAssertEqual(e.update(input(hrv: 47, triggers: [.elevatedAtRest]), now: at(3)).state.mood, .calm)
        XCTAssertEqual(e.update(input(hrv: 47), now: at(5)).state.mood, .calm)
        XCTAssertEqual(e.update(input(hrv: 47), now: at(9)).state.mood, .concerned)
    }

    func testHRZones() {
        let e = settledEngine()
        XCTAssertEqual(e.update(input(hr: 55), now: at(1)).state.hrZone, .below)
        XCTAssertEqual(e.update(input(hr: 65), now: at(2)).state.hrZone, .baseline)
        XCTAssertEqual(e.update(input(hr: 80), now: at(3)).state.hrZone, .elevated)
        let high = e.update(input(hr: 0.75 * (208 - 0.7 * 70)), now: at(4)).state
        XCTAssertEqual(high.hrZone, .high)
        XCTAssertFalse(high.overlays.contains(.steam))
    }

    func testNotWornSleeps() {
        let e = settledEngine()
        let s = e.update(input(worn: false), now: at(1)).state
        XCTAssertEqual(s.motion, .sleep)
        XCTAssertFalse(s.bandWorn)
    }

    func testCadencePassesThrough() {
        XCTAssertEqual(settledEngine().update(input(cadence: 112), now: at(1)).state.cadence, 112)
    }

    func testSleepAppliesImmediatelyMidWalk() {
        let e = settledEngine()
        _ = e.update(input(activity: .walk), now: at(1))
        XCTAssertEqual(e.update(input(activity: .walk), now: at(5)).state.motion, .walk)
        let s = e.update(input(hasData: false), now: at(6)).state
        XCTAssertEqual(s.motion, .sleep)
        XCTAssertEqual(s.mood, .sleeping)
    }

    func testResetSessionClearsHolds() {
        let e = CompanionEngine()
        XCTAssertEqual(e.update(input(hrv: 47), now: at(0)).state.mood, .calm)
        e.resetSession()
        XCTAssertEqual(e.update(input(hrv: 31), now: at(1)).state.mood, .tired, "no mood hold after reset")
        e.resetSession()
        _ = e.update(input(), now: at(2))
        e.resetSession()
        XCTAssertEqual(e.update(input(activity: .walk), now: at(3)).state.motion, .walk, "no motion hold after reset")
    }

    func testSyntheticSessionSequence() {
        let store = MetricsStore()
        let triggers = TriggerEngine()
        let companion = CompanionEngine()
        var smoother = ActivitySmoother()
        let items = SyntheticSession.make()
        var idx = 0
        var motions: [CompanionMotion] = []
        var activeMotionDuringEffort = false
        var relievedAfterEffort = false
        var tick = 0.0
        while tick <= SyntheticSession.total {
            while idx < items.count && items[idx].t <= tick {
                store.ingest(items[idx].input, at: t0.addingTimeInterval(items[idx].t))
                idx += 1
            }
            let now = t0.addingTimeInterval(tick)
            var changed: ActivityClass?
            var previous: ActivityClass?
            if Int(tick) % 5 == 0, let w = store.accelWindow(now: now) {
                let (cls, p) = ActivityMath.heuristic(window: w)
                previous = smoother.current
                changed = smoother.update(cls, probability: p)
                store.ingest(activity: ActivityPoint(t: now, activity: smoother.current ?? cls, probability: p))
            }
            let fired = triggers.evaluate(store, now: now, activityChangedTo: changed, previousActivity: previous).map { $0.kind }
            let hr = store.stats(.heartRate, seconds: 5, now: now)?.latest
            let ci = CompanionInput(hr: hr,
                                    hrv: store.stats(.hrv, seconds: 30, now: now)?.latest,
                                    skinTemp: store.stats(.skinTemp, seconds: 30, now: now)?.latest,
                                    baselineHR: store.baseline.heartRate, baselineHRV: store.baseline.hrv,
                                    baselineSkinTemp: store.baseline.skinTemp,
                                    activity: store.currentActivity(now: now),
                                    hasData: hr != nil, worn: store.isWorn,
                                    calibrating: store.calibrationProgress < 1, triggers: fired)
            let s = companion.update(ci, now: now).state
            if motions.last != s.motion { motions.append(s.motion) }
            if tick >= 150, tick <= 210, s.motion == .trot || s.motion == .walk { activeMotionDuringEffort = true }
            if tick > 210, s.mood == .relieved { relievedAfterEffort = true }
            tick += 1
        }
        XCTAssertTrue(activeMotionDuringEffort, "\(motions)")
        XCTAssertTrue(relievedAfterEffort)
        let active = motions.firstIndex { $0 == .trot || $0 == .walk }
        XCTAssertNotNil(active, "\(motions)")
        XCTAssertTrue(motions[..<active!].contains(.idle), "\(motions)")
        XCTAssertEqual(motions.last, .idle, "\(motions)")
    }
}
