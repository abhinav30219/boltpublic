import Foundation

/// Every threshold, timing and rate for the companion feature. Missing keys in a
/// saved file keep their defaults.
public struct Tuning: Codable, Sendable, Equatable {
    public var companion = CompanionTuning()
    public var fall = FallTuning()
    public var render = RenderTuning()
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        companion = try c.decodeIfPresent(CompanionTuning.self, forKey: .companion) ?? companion
        fall = try c.decodeIfPresent(FallTuning.self, forKey: .fall) ?? fall
        render = try c.decodeIfPresent(RenderTuning.self, forKey: .render) ?? render
    }

    /// Missing file gives defaults and no error; unreadable or invalid JSON gives defaults and a message.
    public static func load(from url: URL) -> (tuning: Tuning, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Tuning(), nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(Tuning.self, from: data), nil)
        } catch {
            return (Tuning(), "Could not read tuning file: \(error.localizedDescription)")
        }
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

/// Companion engine: mood/motion timing, metric thresholds, gait geometry.
public struct CompanionTuning: Codable, Sendable, Equatable {
    public var motionHoldSeconds: Double = 3
    public var moodHoldSeconds: Double = 8
    public var relievedSeconds: Double = 20
    public var concernedSeconds: Double = 20
    public var happySeconds: Double = 10
    public var blushStartAboveBaselineBpm: Double = 10
    public var blushFullFractionOfMax: Double = 0.85
    public var steamFractionOfMax: Double = 0.85
    public var elevatedAboveBaselineBpm: Double = 10
    public var belowBaselineBpm: Double = 5
    public var highFractionOfMax: Double = 0.70
    public var calmHRVAboveBaseline: Double = 0.15
    public var tiredHRVBelowBaseline: Double = 0.20
    public var tempShiftC: Double = 0.5
    public var milestoneSteps: Int = 1000
    public var dailyStepGoal: Int = 8000
    public var defaultAge: Int = 40
    public var frontKneeMaxDeg: Double = 25
    public var backKneeMaxDeg: Double = 60
    public var walkHipDeg: Double = 20
    public var trotHipDeg: Double = 30
    public var backKneeWalkDeg: Double = 25
    public var bodyBobMeters: Double = 0.012
    public var idleLookYawDeg: Double = 8
    public var breathPeriodSeconds: Double = 3.5
    public var transitionSeconds: Double = 0.4
    public var celebrationSeconds: Double = 0.8
    public var meaningBusyAboveBaselineBpm: Double = 25
    public var meaningActiveKcal: Double = 100
    public var meaningOxygenLowPct: Double = 95
    public var meaningRestedFractionOfBaseline: Double = 0.85
    /// Robot twin: seconds per `kwkF`/`kwkB` gait cycle, cadence while it walks, gaze lean limits.
    public var robotWalkCycleSeconds: Double = 1.2
    public var robotWalkCadence: Double = 100
    public var robotGazeMaxYawDeg: Double = 20
    public var robotGazeMaxPitchDeg: Double = 10
    /// Robot twin one-shots: the wave (`khi`) and the backflip (`kflipRoll`).
    public var robotWaveSeconds: Double = 1.5
    /// Idle life: weight-shift roll (degrees), seconds between leg fidgets, head tilt (degrees).
    public var idleSwayDeg: Double = 3.5
    public var idleFidgetMinSeconds: Double = 6
    public var idleFidgetMaxSeconds: Double = 12
    public var idleLookPitchDeg: Double = 5
    public var robotFlipSeconds: Double = 1.2
    /// Minimum gap between robot waves triggered by a wrist wave.
    public var waveRobotCooldownSeconds: Double = 10
    /// Camera pull-back at the peak of a flip, as a fraction of the normal distance, so the body stays in frame.
    public var flipCameraPullback: Double = 0.6
    /// Seconds after the finger lifts before a dragged-round companion springs back to the default view.
    public var touchReturnSeconds: Double = 3
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        motionHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .motionHoldSeconds) ?? motionHoldSeconds
        moodHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .moodHoldSeconds) ?? moodHoldSeconds
        relievedSeconds = try c.decodeIfPresent(Double.self, forKey: .relievedSeconds) ?? relievedSeconds
        concernedSeconds = try c.decodeIfPresent(Double.self, forKey: .concernedSeconds) ?? concernedSeconds
        happySeconds = try c.decodeIfPresent(Double.self, forKey: .happySeconds) ?? happySeconds
        blushStartAboveBaselineBpm = try c.decodeIfPresent(Double.self, forKey: .blushStartAboveBaselineBpm) ?? blushStartAboveBaselineBpm
        blushFullFractionOfMax = try c.decodeIfPresent(Double.self, forKey: .blushFullFractionOfMax) ?? blushFullFractionOfMax
        steamFractionOfMax = try c.decodeIfPresent(Double.self, forKey: .steamFractionOfMax) ?? steamFractionOfMax
        elevatedAboveBaselineBpm = try c.decodeIfPresent(Double.self, forKey: .elevatedAboveBaselineBpm) ?? elevatedAboveBaselineBpm
        belowBaselineBpm = try c.decodeIfPresent(Double.self, forKey: .belowBaselineBpm) ?? belowBaselineBpm
        highFractionOfMax = try c.decodeIfPresent(Double.self, forKey: .highFractionOfMax) ?? highFractionOfMax
        calmHRVAboveBaseline = try c.decodeIfPresent(Double.self, forKey: .calmHRVAboveBaseline) ?? calmHRVAboveBaseline
        tiredHRVBelowBaseline = try c.decodeIfPresent(Double.self, forKey: .tiredHRVBelowBaseline) ?? tiredHRVBelowBaseline
        tempShiftC = try c.decodeIfPresent(Double.self, forKey: .tempShiftC) ?? tempShiftC
        milestoneSteps = try c.decodeIfPresent(Int.self, forKey: .milestoneSteps) ?? milestoneSteps
        dailyStepGoal = try c.decodeIfPresent(Int.self, forKey: .dailyStepGoal) ?? dailyStepGoal
        touchReturnSeconds = try c.decodeIfPresent(Double.self, forKey: .touchReturnSeconds) ?? touchReturnSeconds
        defaultAge = try c.decodeIfPresent(Int.self, forKey: .defaultAge) ?? defaultAge
        frontKneeMaxDeg = try c.decodeIfPresent(Double.self, forKey: .frontKneeMaxDeg) ?? frontKneeMaxDeg
        backKneeMaxDeg = try c.decodeIfPresent(Double.self, forKey: .backKneeMaxDeg) ?? backKneeMaxDeg
        walkHipDeg = try c.decodeIfPresent(Double.self, forKey: .walkHipDeg) ?? walkHipDeg
        trotHipDeg = try c.decodeIfPresent(Double.self, forKey: .trotHipDeg) ?? trotHipDeg
        backKneeWalkDeg = try c.decodeIfPresent(Double.self, forKey: .backKneeWalkDeg) ?? backKneeWalkDeg
        bodyBobMeters = try c.decodeIfPresent(Double.self, forKey: .bodyBobMeters) ?? bodyBobMeters
        idleLookYawDeg = try c.decodeIfPresent(Double.self, forKey: .idleLookYawDeg) ?? idleLookYawDeg
        breathPeriodSeconds = try c.decodeIfPresent(Double.self, forKey: .breathPeriodSeconds) ?? breathPeriodSeconds
        transitionSeconds = try c.decodeIfPresent(Double.self, forKey: .transitionSeconds) ?? transitionSeconds
        celebrationSeconds = try c.decodeIfPresent(Double.self, forKey: .celebrationSeconds) ?? celebrationSeconds
        meaningBusyAboveBaselineBpm = try c.decodeIfPresent(Double.self, forKey: .meaningBusyAboveBaselineBpm) ?? meaningBusyAboveBaselineBpm
        meaningActiveKcal = try c.decodeIfPresent(Double.self, forKey: .meaningActiveKcal) ?? meaningActiveKcal
        meaningOxygenLowPct = try c.decodeIfPresent(Double.self, forKey: .meaningOxygenLowPct) ?? meaningOxygenLowPct
        meaningRestedFractionOfBaseline = try c.decodeIfPresent(Double.self, forKey: .meaningRestedFractionOfBaseline) ?? meaningRestedFractionOfBaseline
        robotWalkCycleSeconds = try c.decodeIfPresent(Double.self, forKey: .robotWalkCycleSeconds) ?? robotWalkCycleSeconds
        robotWalkCadence = try c.decodeIfPresent(Double.self, forKey: .robotWalkCadence) ?? robotWalkCadence
        robotGazeMaxYawDeg = try c.decodeIfPresent(Double.self, forKey: .robotGazeMaxYawDeg) ?? robotGazeMaxYawDeg
        robotGazeMaxPitchDeg = try c.decodeIfPresent(Double.self, forKey: .robotGazeMaxPitchDeg) ?? robotGazeMaxPitchDeg
        idleSwayDeg = try c.decodeIfPresent(Double.self, forKey: .idleSwayDeg) ?? idleSwayDeg
        idleFidgetMinSeconds = try c.decodeIfPresent(Double.self, forKey: .idleFidgetMinSeconds) ?? idleFidgetMinSeconds
        idleFidgetMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .idleFidgetMaxSeconds) ?? idleFidgetMaxSeconds
        idleLookPitchDeg = try c.decodeIfPresent(Double.self, forKey: .idleLookPitchDeg) ?? idleLookPitchDeg
        robotWaveSeconds = try c.decodeIfPresent(Double.self, forKey: .robotWaveSeconds) ?? robotWaveSeconds
        robotFlipSeconds = try c.decodeIfPresent(Double.self, forKey: .robotFlipSeconds) ?? robotFlipSeconds
        waveRobotCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .waveRobotCooldownSeconds) ?? waveRobotCooldownSeconds
        flipCameraPullback = try c.decodeIfPresent(Double.self, forKey: .flipCameraPullback) ?? flipCameraPullback
    }
}

/// Fall flow settings. The detector itself (`Safety/FallDetector`) is a fitted model with no
/// tunable thresholds; old keys from earlier tuning.json files are ignored when decoding.
public struct FallTuning: Codable, Sendable, Equatable {
    /// Minimum gap between two fall checks, in seconds.
    public var cooldownSeconds: Double = 120
    public var responseTimeoutSeconds: Double = 30
    /// The robot asks once more this long after the fall check opens.
    public var reaskSeconds: Double = 15
    /// Gap between alarm lines once the alarm is sounding.
    public var alarmRepeatSeconds: Double = 5
    public var emergencyNumber: String = "911"
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .cooldownSeconds) ?? cooldownSeconds
        responseTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .responseTimeoutSeconds) ?? responseTimeoutSeconds
        reaskSeconds = try c.decodeIfPresent(Double.self, forKey: .reaskSeconds) ?? reaskSeconds
        alarmRepeatSeconds = try c.decodeIfPresent(Double.self, forKey: .alarmRepeatSeconds) ?? alarmRepeatSeconds
        emergencyNumber = try c.decodeIfPresent(String.self, forKey: .emergencyNumber) ?? emergencyNumber
    }
}

/// Renderer frame rates and style.
public struct RenderTuning: Codable, Sendable, Equatable {
    public var visibleFPS: Double = 30
    public var generatingFPS: Double = 20
    public var outlineWidth: Double = 0.008
    public var reduceAnimation: Bool = false
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visibleFPS = try c.decodeIfPresent(Double.self, forKey: .visibleFPS) ?? visibleFPS
        generatingFPS = try c.decodeIfPresent(Double.self, forKey: .generatingFPS) ?? generatingFPS
        outlineWidth = try c.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? outlineWidth
        reduceAnimation = try c.decodeIfPresent(Bool.self, forKey: .reduceAnimation) ?? reduceAnimation
    }
}
