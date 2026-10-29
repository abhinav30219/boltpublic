import Foundation
import CoreMotion
import BoltCore

/// On-device activity and step tracking using Apple's own Core Motion frameworks:
/// `CMMotionActivityManager` for the walk/run/still/cycle classification Apple ships,
/// and `CMPedometer` for steps, cadence and distance. It produces the same
/// `FitnessInterval` windows and `FitnessTotals` the rest of the app already consumes, so
/// nothing downstream had to change. No custom model and no raw-accel export.
@MainActor
final class MotionActivityEngine: ObservableObject {
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()

    /// Published activity state, mirroring the shape the Live/Home views read.
    @Published private(set) var state = FitnessState()
    @Published private(set) var current: ActivityClass = .stationary
    @Published private(set) var windowCount = 0

    var profile = FitnessProfile()
    /// Called when a 30 s window is finalized, so the app can persist it.
    var onWindow: ((FitnessInterval) -> Void)?

    private var timeline = FitnessTimeline()
    private var started = false
    private var latestActivity: CMMotionActivity?
    private var windowTimer: Timer?

    static var isAvailable: Bool {
        CMMotionActivityManager.isActivityAvailable() && CMPedometer.isStepCountingAvailable()
    }

    func start() {
        guard Self.isAvailable, !started else { return }
        started = true
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.latestActivity = activity
            self.current = Self.classOf(activity)
        }
        // Finalize a window every 30 s, aligned to the wall clock, like the old pipeline's grid.
        windowTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.finalizeWindow() }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        activityManager.stopActivityUpdates()
        windowTimer?.invalidate(); windowTimer = nil
    }

    func reset() {
        timeline = FitnessTimeline()
        state = FitnessState()
        windowCount = 0
        current = .stationary
        latestActivity = nil
    }

    private func finalizeWindow() {
        let now = Date()
        let start = now.addingTimeInterval(-30)
        let cls = latestActivity.map(Self.classOf) ?? .stationary
        let label = Self.label(for: cls)

        pedometer.queryPedometerData(from: start, to: now) { [weak self] data, _ in
            Task { @MainActor in
                guard let self else { return }
                let steps = data?.numberOfSteps.intValue ?? 0
                let cadencePerSec = data?.currentCadence?.doubleValue ?? 0
                let cadence = cadencePerSec > 0 ? cadencePerSec * 60 : (label.isLocomotor ? Double(steps) * 2 : 0)
                self.appendWindow(start: start, end: now, label: label, steps: steps, cadence: cadence)
            }
        }
    }

    private func appendWindow(start: Date, end: Date, label: FitnessLabel, steps: Int, cadence: Double) {
        var m = FitnessMetrics()
        m.steps = steps
        m.cadence = cadence
        m.band = Self.intensityBand(for: label)
        m.kcal = Self.kcal(label: label, minutes: 0.5, profile: profile)
        let interval = FitnessInterval(start: start.timeIntervalSince1970, end: end.timeIntervalSince1970,
                                   label: label, metrics: m, active: !label.isNonActive, hr: 0)
        timeline.insert([interval], source: .live)
        var s = FitnessState()
        s.timeline = timeline
        s.latest = interval
        state = s
        windowCount += 1
        onWindow?(interval)
    }

    var todayTotals: FitnessTotals { timeline.today() }

    static func classOf(_ a: CMMotionActivity) -> ActivityClass {
        if a.running { return .run }
        if a.cycling { return .cycle }
        if a.walking { return .walk }
        if a.automotive { return .generalMovement }
        if a.stationary { return .stationary }
        return .generalMovement
    }

    static func label(for c: ActivityClass) -> FitnessLabel {
        switch c {
        case .stationary: return .stationary
        case .generalMovement: return .generalMovement
        case .walk, .stairs: return .walk
        case .run: return .run
        case .cycle: return .cycle
        }
    }

    static func intensityBand(for label: FitnessLabel) -> Int {
        switch label {
        case .run: return 3
        case .walk, .cycle: return 2
        case .generalMovement: return 1
        default: return 0
        }
    }

    /// Simple MET-based estimate so energy still moves; not a clinical figure.
    static func kcal(label: FitnessLabel, minutes: Double, profile: FitnessProfile) -> Double {
        let met: Double
        switch label {
        case .run: met = 8.0
        case .walk: met = 3.5
        case .cycle: met = 6.0
        case .generalMovement: met = 2.0
        default: met = 1.0
        }
        return met * 3.5 * profile.mass / 200 * minutes
    }
}
