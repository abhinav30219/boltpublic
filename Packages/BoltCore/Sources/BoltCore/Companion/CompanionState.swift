import Foundation

public enum CompanionMotion: UInt8, Sendable { case idle = 0, walk = 1, trot = 2, sleep = 3 }

public enum CompanionMood: UInt8, Sendable {
    case neutral = 0, happy, calm, tired, concerned, determined, relieved, scanning, sleeping
}

public enum CompanionOverlay: String, CaseIterable, Sendable { case sweat, steam, frost, zzz }

public enum CompanionEvent: UInt8, Sendable {
    case stepMilestone = 1, goalReached, recovery, fallSuspected, fallResolved, bandOff
}

public enum HRZone: UInt8, Sendable { case below = 0, baseline, elevated, high, veryHigh }

/// What the companion looks like right now.
public struct CompanionState: Equatable, Sendable {
    public var motion: CompanionMotion = .sleep
    public var cadence: Double = 0
    public var mood: CompanionMood = .sleeping
    public var blush: Double = 0
    public var overlays: Set<CompanionOverlay> = [.zzz]
    public var hrZone: HRZone = .baseline
    public var stepsToday = 0
    public var bandWorn = false
    public var userWalking = false
    public var fallAlertActive = false
    public init() {}
}

/// One tick of live inputs for the companion.
public struct CompanionInput: Sendable {
    public var hr, hrv, skinTemp: Double?
    public var baselineHR, baselineHRV, baselineSkinTemp: Double?
    public var activity: ActivityClass?
    public var hasData: Bool
    public var worn: Bool
    public var calibrating: Bool
    public var age: Double?
    public var steps: Int
    public var cadence: Double
    public var triggers: [TriggerKind]
    public var fallAlertActive: Bool
    public var fallResolved: Bool

    public init(hr: Double? = nil, hrv: Double? = nil, skinTemp: Double? = nil,
                baselineHR: Double? = nil, baselineHRV: Double? = nil, baselineSkinTemp: Double? = nil,
                activity: ActivityClass? = nil, hasData: Bool = false, worn: Bool = false,
                calibrating: Bool = false, age: Double? = nil, steps: Int = 0, cadence: Double = 0,
                triggers: [TriggerKind] = [], fallAlertActive: Bool = false, fallResolved: Bool = false) {
        self.hr = hr; self.hrv = hrv; self.skinTemp = skinTemp
        self.baselineHR = baselineHR; self.baselineHRV = baselineHRV; self.baselineSkinTemp = baselineSkinTemp
        self.activity = activity; self.hasData = hasData; self.worn = worn
        self.calibrating = calibrating; self.age = age; self.steps = steps; self.cadence = cadence
        self.triggers = triggers; self.fallAlertActive = fallAlertActive; self.fallResolved = fallResolved
    }
}
