import Foundation

// Activity data containers. These describe a 30-second activity window and a
// wearer profile. They are source-agnostic: on this public build the windows are
// produced from the iPhone's own Core Motion activity classifier and pedometer
// (see the app's MotionActivityEngine), but any producer that fills these shapes works.

public enum FitnessSex: String, Sendable { case male, female, unspecified }

/// Wearer profile used for energy estimates. Defaults: 40 y, 70 kg, resting HR 60.
public struct FitnessProfile: Equatable, Sendable {
    public var age: Double
    public var mass: Double
    public var restingHr: Double
    public var maxHr: Double?
    public var sex: FitnessSex

    public init(age: Double = 40, mass: Double = 70, restingHr: Double = 60, maxHr: Double? = nil, sex: FitnessSex = .unspecified) {
        self.age = age; self.mass = mass; self.restingHr = restingHr; self.maxHr = maxHr; self.sex = sex
    }

    /// `maxHr` when finite and > 100, else 208 - 0.7 * age.
    public var effectiveMaxHr: Double {
        if let m = maxHr, m.isFinite, m > 100 { return m }
        return 208 - 0.7 * age
    }
}

/// Final per-window activity label.
public enum FitnessLabel: String, CaseIterable, Sendable {
    case stationary, generalMovement = "general_movement", walk, run, cycle, uncertain, sleeping, notWorn = "not_worn"

    /// Steps and cadence are only admitted for these.
    public var isLocomotor: Bool { self == .walk || self == .run }
    /// stationary, sleeping, not worn and uncertain windows are not "active".
    public var isNonActive: Bool { self == .stationary || self == .sleeping || self == .notWorn || self == .uncertain }
}

/// Per-window metrics.
public struct FitnessMetrics: Equatable, Sendable {
    public var enmoMg = 0.0
    public var cadence = 0.0
    public var kcal = 0.0
    public var hrWeight = 0.0
    public var steps = 0
    /// 0 sedentary, 1 light, 2 medium, 3 high (standard ENMO bands 44.8 / 100.6 / 428.8 mg).
    public var band = 0
    public var hrAvailable = false
    public init() {}
}

/// A finalized 30 s window. `start`/`end` are unix seconds.
public struct FitnessInterval: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var label: FitnessLabel
    public var metrics: FitnessMetrics
    public var active: Bool
    public var hr: Double
    public init(start: Double, end: Double, label: FitnessLabel, metrics: FitnessMetrics, active: Bool, hr: Double) {
        self.start = start; self.end = end; self.label = label; self.metrics = metrics; self.active = active; self.hr = hr
    }
}

/// A continuous bout of walk/run/cycle.
public struct FitnessBout: Equatable, Sendable {
    public var type: FitnessLabel
    public var start: Double
    public var end: Double
    public var durationMin: Double
    public var kcal: Double
    public var averageHr: Double?
    public var peakHr: Double?
    public var hrZone: Int
    public init(type: FitnessLabel, start: Double, end: Double, durationMin: Double, kcal: Double,
                averageHr: Double? = nil, peakHr: Double? = nil, hrZone: Int = 0) {
        self.type = type; self.start = start; self.end = end; self.durationMin = durationMin
        self.kcal = kcal; self.averageHr = averageHr; self.peakHr = peakHr; self.hrZone = hrZone
    }
}
