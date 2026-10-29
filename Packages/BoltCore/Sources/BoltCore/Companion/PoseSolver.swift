import Foundation

public enum Leg: String, CaseIterable, Sendable {
    case FL, FR, BL, BR
    public var isFront: Bool { self == .FL || self == .FR }
}

public enum JointKind: String, CaseIterable, Sendable { case hip, knee, ankle }

public struct JointID: Hashable, Sendable {
    public var kind: JointKind
    public var leg: Leg
    public init(kind: JointKind, leg: Leg) { self.kind = kind; self.leg = leg }
    public var nodeName: String { "\(kind.rawValue)_\(leg.rawValue)" }
}

/// Joint angles (radians about each joint's local X; positive swings the foot toward the back)
/// plus whole-body offsets.
public struct Pose: Equatable, Sendable {
    public var angles: [JointID: Double]
    public var bodyLift: Double
    public var bodyPitch: Double
    public var bodyRoll: Double
    public var bodyYaw: Double
    /// 0...1: how far the renderer should pull its camera back to keep the whole body in frame.
    /// Eases in and out around a flip; 0 otherwise.
    public var framing: Double

    public init(angles: [JointID: Double], bodyLift: Double = 0, bodyPitch: Double = 0, bodyRoll: Double = 0, bodyYaw: Double = 0, framing: Double = 0) {
        self.framing = framing
        self.angles = angles; self.bodyLift = bodyLift
        self.bodyPitch = bodyPitch; self.bodyRoll = bodyRoll; self.bodyYaw = bodyYaw
    }

    public static let rest = Pose(angles: Dictionary(uniqueKeysWithValues:
        Leg.allCases.flatMap { leg in JointKind.allCases.map { (JointID(kind: $0, leg: leg), 0.0) } }))
}

/// A body lean override in degrees (robot twin gaze).
public struct PoseGaze: Equatable, Sendable {
    public var yawDeg: Double, pitchDeg: Double
    public init(yawDeg: Double, pitchDeg: Double) { self.yawDeg = yawDeg; self.pitchDeg = pitchDeg }
}

/// Turns companion state plus time into joint angles. Deterministic for a given seed.
public struct PoseSolver {
    public var tuning: CompanionTuning
    public private(set) var gaitPhase: Double = 0   // cycles; one cycle is two steps
    /// False runs the gait phase backward, so the legs swing in reverse.
    public var walkForward: Bool = true
    /// When set, the body yaw/pitch targets follow it and the random idle look-around is off.
    public var gaze: PoseGaze?

    // Choreography (not tuning; see controller ruling R8).
    private static let tiredLift = -0.01, tiredPitchDeg = 4.0
    private static let concernedRollDeg = 5.0
    private static let happyBounceMeters = 0.006, happyBounceHz = 2.0
    private static let sleepLift = -0.03, sleepKneeFraction = 0.6
    private static let breathFraction = 0.3
    private static let frontKneeFactor = 0.4, ankleFactor = 0.5
    private static let lookIntervalSeconds = 4.0...7.0
    private static let fallbackWalkCadence = 100.0, fallbackTrotCadence = 160.0
    private static let cadenceDivisor = 120.0
    /// (progress, lift in meters): crouch, extend, land.
    private static let celebrationCurve: [(t: Double, lift: Double)] = [(0, 0), (0.3, -0.02), (0.6, 0.04), (1, 0)]

    private struct Spring {
        var x = 0.0, v = 0.0
        /// Critically damped, exact for any dt.
        mutating func step(to target: Double, dt: Double, tau: Double) {
            guard tau > 0 else { x = target; v = 0; return }
            let w = 1 / tau
            let d0 = x - target
            let c = v + w * d0
            let e = exp(-w * dt)
            x = target + (d0 + c * dt) * e
            v = (v - w * c * dt) * e
        }
    }

    private struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
    }

    private var rng: LCG
    private var time = 0.0
    private var nextLookAt = 0.0
    private var lookTargetYaw = 0.0
    private var celebrationStart: Double?
    private var oneShotKind: OneShot?
    private var oneShotStart = 0.0

    /// False keeps only breathing and the random look (Reduce Motion).
    public var idleLife = true
    /// Fidgets started so far (a test and debugging aid).
    public private(set) var idleFidgetCount = 0

    private enum FidgetKind { case pawLift, shuffle, settle }
    private struct Fidget { var kind: FidgetKind; var leg: Leg; var start: Double; var duration: Double }
    private var lifeRng: LCG
    private var idleBlend = Spring(), sway = Spring(), tilt = Spring()
    private var swayTarget = 0.0, nextSwayAt = 2.0, tiltTarget = 0.0, nextTiltAt = 4.0
    private var scanStart: Double?, nextScanAt = 9.0
    private var fidget: Fidget?
    private var nextFidgetAt: Double?
    // Idle choreography. Amplitudes are kept small so a 30 fps frame never moves a joint more than ~3 degrees.
    private static let swayKneeDeg = 6.0, scanSeconds = 3.5, scanYawFactor = 1.5
    private static let pawHipDeg = 14.0, pawKneeDeg = 14.0, pawSeconds = 0.6
    private static let shuffleHipDeg = 8.0, shuffleKneeDeg = 12.0, shuffleSeconds = 0.5
    private static let settleLift = -0.012, settleSeconds = 0.7

    /// Body animations the robot twin plays on top of whatever else the body is doing.
    public enum OneShot: Equatable, Sendable { case wave, flip }

    // Wave: front-right hip raised forward, knee waved `waveCount` times.
    private static let waveHipDeg = 55.0, waveCount = 3.0, waveBodyPitchDeg = 3.0, waveWristFactor = 0.5
    // Flip: lift, tuck and rotation timeline as fractions of the duration.
    private static let flipLiftMeters = 0.16, flipCrouchMeters = -0.02
    private static let flipCrouchEnd = 0.18, flipTakeoff = 0.3, flipLand = 0.78, flipSettle = 0.9
    private static let flipTuckHipDeg = 30.0
    /// Fraction of the flip spent easing the camera out, and again easing it back.
    private static let flipFramingRamp = 0.15

    private var hipAmp = Spring(), gaitBlend = Spring(), sleepBlend = Spring(), happyBlend = Spring()
    private var lift = Spring(), pitch = Spring(), roll = Spring(), yaw = Spring()

    public init(tuning: CompanionTuning = .init(), seed: UInt64 = 1) {
        self.tuning = tuning
        self.rng = LCG(s: seed)
        self.lifeRng = LCG(s: seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    public mutating func celebrate() { celebrationStart = time }

    /// An idle behaviour that can be triggered on demand (the animation lab). Idle plays them on its own otherwise.
    public enum IdleFidget: String, CaseIterable, Sendable { case pawLift, shuffle, settle, headTilt, look, sway }

    /// Starts `kind` now, as if the idle timer had picked it. It shows only while standing idle (not walking,
    /// asleep, mid one-shot or gazing, and with `idleLife` on). Deterministic: always the same leg and side.
    public mutating func forceIdleFidget(_ kind: IdleFidget) {
        switch kind {
        case .pawLift: fidget = Fidget(kind: .pawLift, leg: .FR, start: time, duration: Self.pawSeconds); idleFidgetCount += 1
        case .shuffle: fidget = Fidget(kind: .shuffle, leg: .BL, start: time, duration: Self.shuffleSeconds); idleFidgetCount += 1
        case .settle: fidget = Fidget(kind: .settle, leg: .FL, start: time, duration: Self.settleSeconds); idleFidgetCount += 1
        case .headTilt: tiltTarget = 1; nextTiltAt = time + 2
        case .look: scanStart = time
        case .sway: swayTarget = 1; nextSwayAt = time + 3
        }
    }

    /// Starts a wave or flip now (replacing any in progress).
    public mutating func play(_ shot: OneShot) { oneShotKind = shot; oneShotStart = time; fidget = nil }

    public mutating func step(state: CompanionState, dt: Double) -> Pose {
        let dt = max(0, dt)
        let tau = tuning.transitionSeconds
        time += dt
        let deg = Double.pi / 180

        let walking = state.motion == .walk || state.motion == .trot
        let sleeping = state.motion == .sleep
        if walking {
            let fallback = state.motion == .trot ? Self.fallbackTrotCadence : Self.fallbackWalkCadence
            let cadence = state.cadence > 0 ? state.cadence : fallback
            gaitPhase += (walkForward ? 1 : -1) * dt * cadence / Self.cadenceDivisor
        }

        // Smoothed targets: gait amplitude, posture blends and body channels. The gait
        // sinusoid itself is computed from these and the continuous phase.
        let frontKneeMax = tuning.frontKneeMaxDeg * deg
        let backKneeMax = tuning.backKneeMaxDeg * deg
        let ampRad = (state.motion == .trot ? tuning.trotHipDeg : tuning.walkHipDeg) * deg
        hipAmp.step(to: walking ? ampRad : 0, dt: dt, tau: tau)
        gaitBlend.step(to: walking ? 1 : 0, dt: dt, tau: tau)
        sleepBlend.step(to: sleeping ? Self.sleepKneeFraction : 0, dt: dt, tau: tau)
        happyBlend.step(to: (!sleeping && state.mood == .happy) ? 1 : 0, dt: dt, tau: tau)

        var liftTarget = sleeping ? Self.sleepLift : 0
        var pitchTarget = 0.0, rollTarget = 0.0
        if !sleeping {
            switch state.mood {
            case .tired: liftTarget += Self.tiredLift; pitchTarget = Self.tiredPitchDeg * deg
            case .concerned: rollTarget = Self.concernedRollDeg * deg
            default: break
            }
        }
        if let gaze {
            lookTargetYaw = gaze.yawDeg * deg
            pitchTarget = gaze.pitchDeg * deg
        } else if state.motion == .idle {
            if time >= nextLookAt {
                let span = Self.lookIntervalSeconds
                nextLookAt = time + span.lowerBound + rng.next() * (span.upperBound - span.lowerBound)
                lookTargetYaw = (rng.next() * 2 - 1) * tuning.idleLookYawDeg * deg
            }
        } else {
            lookTargetYaw = 0
        }
        // Idle life: sway, head tilt, scan and leg fidgets, only while standing idle and nothing else plays.
        let idleOK = idleLife && state.motion == .idle && oneShotKind == nil && gaze == nil
        idleBlend.step(to: idleOK ? 1 : 0, dt: dt, tau: tau)
        var extraHip: [Leg: Double] = [:], extraKnee: [Leg: Double] = [:]
        var fidgetLift = 0.0
        if idleOK {
            if time >= nextSwayAt {
                swayTarget = lifeRng.next() < 0.25 ? 0 : lifeRng.next() * 2 - 1
                nextSwayAt = time + 3 + lifeRng.next() * 3
            }
            if time >= nextTiltAt {
                if tiltTarget != 0 { tiltTarget = 0; nextTiltAt = time + 3 + lifeRng.next() * 4 }
                else { tiltTarget = lifeRng.next() < 0.5 ? -1 : 1; nextTiltAt = time + 1.5 + lifeRng.next() * 1.5 }
            }
            if scanStart == nil && time >= nextScanAt { scanStart = time }
            let lo = max(0.1, tuning.idleFidgetMinSeconds), hi = max(lo, tuning.idleFidgetMaxSeconds)
            if nextFidgetAt == nil { nextFidgetAt = time + lo + lifeRng.next() * (hi - lo) }
            if fidget == nil, idleBlend.x > 0.95, time >= (nextFidgetAt ?? .infinity) {
                let r = lifeRng.next()
                let front: [Leg] = [.FL, .FR], back: [Leg] = [.BL, .BR]
                let pick = lifeRng.next() < 0.5 ? 0 : 1
                if r < 0.4 { fidget = Fidget(kind: .pawLift, leg: front[pick], start: time, duration: Self.pawSeconds) }
                else if r < 0.75 { fidget = Fidget(kind: .shuffle, leg: back[pick], start: time, duration: Self.shuffleSeconds) }
                else { fidget = Fidget(kind: .settle, leg: .FL, start: time, duration: Self.settleSeconds) }
                idleFidgetCount += 1
            }
        } else {
            swayTarget = 0; tiltTarget = 0; scanStart = nil
            nextFidgetAt = nil
        }
        sway.step(to: swayTarget, dt: dt, tau: 0.9)
        tilt.step(to: tiltTarget, dt: dt, tau: 0.6)
        let life = idleBlend.x
        if let f = fidget {
            let p = (time - f.start) / f.duration
            if p >= 1 {
                fidget = nil
                let lo = max(0.1, tuning.idleFidgetMinSeconds), hi = max(lo, tuning.idleFidgetMaxSeconds)
                nextFidgetAt = time + lo + lifeRng.next() * (hi - lo)
            } else {
                let e = sin(Double.pi * p) * life
                switch f.kind {
                case .pawLift: extraHip[f.leg] = -Self.pawHipDeg * deg * e; extraKnee[f.leg] = Self.pawKneeDeg * deg * e
                case .shuffle: extraHip[f.leg] = -Self.shuffleHipDeg * deg * e; extraKnee[f.leg] = Self.shuffleKneeDeg * deg * e
                case .settle: fidgetLift = Self.settleLift * e
                }
            }
        }
        // Weight shift: the loaded side's knees bend a little more.
        for leg in Leg.allCases {
            let right = leg == .FR || leg == .BR
            let loaded = max(0, right ? sway.x : -sway.x)
            extraKnee[leg, default: 0] += Self.swayKneeDeg * deg * loaded * life
        }
        rollTarget += tuning.idleSwayDeg * deg * sway.x * life
        if gaze == nil { pitchTarget += tuning.idleLookPitchDeg * deg * tilt.x * life }
        if let start = scanStart {
            let p = (time - start) / Self.scanSeconds
            if p >= 1 { scanStart = nil; nextScanAt = time + 10 + lifeRng.next() * 10 }
            else { lookTargetYaw = tuning.idleLookYawDeg * deg * Self.scanYawFactor * (2 * Self.smooth(p) - 1) }
        }
        lift.step(to: liftTarget, dt: dt, tau: tau)
        pitch.step(to: pitchTarget, dt: dt, tau: tau)
        roll.step(to: rollTarget, dt: dt, tau: tau)
        yaw.step(to: lookTargetYaw, dt: dt, tau: tau)

        var angles: [JointID: Double] = [:]
        for leg in Leg.allCases {
            let p = 2 * Double.pi * gaitPhase + ((leg == .FL || leg == .BR) ? 0 : Double.pi)
            let swing = max(0, sin(p + Double.pi / 2))
            let hip = hipAmp.x * sin(p) + (extraHip[leg] ?? 0)
            let knee: Double
            if leg.isFront {
                knee = min(max(gaitBlend.x * frontKneeMax * Self.frontKneeFactor * swing + sleepBlend.x * frontKneeMax + (extraKnee[leg] ?? 0),
                               -frontKneeMax), frontKneeMax)
            } else {
                knee = min(max(gaitBlend.x * tuning.backKneeWalkDeg * deg * swing + sleepBlend.x * backKneeMax + (extraKnee[leg] ?? 0),
                               0), backKneeMax)
            }
            angles[JointID(kind: .hip, leg: leg)] = hip
            angles[JointID(kind: .knee, leg: leg)] = knee
            angles[JointID(kind: .ankle, leg: leg)] = -(hip + knee) * Self.ankleFactor
        }

        var bodyLift = lift.x + fidgetLift
        bodyLift += tuning.bodyBobMeters * gaitBlend.x * abs(sin(4 * Double.pi * gaitPhase))
        if tuning.breathPeriodSeconds > 0 {
            let breath = Self.breathFraction * tuning.bodyBobMeters * sin(2 * Double.pi * time / tuning.breathPeriodSeconds)
            bodyLift += breath * (1 - gaitBlend.x)
        }
        bodyLift += happyBlend.x * Self.happyBounceMeters * (0.5 + 0.5 * sin(2 * Double.pi * Self.happyBounceHz * time))
        if let start = celebrationStart {
            let progress = tuning.celebrationSeconds > 0 ? (time - start) / tuning.celebrationSeconds : 1
            if progress >= 1 { celebrationStart = nil } else { bodyLift += Self.celebrationLift(progress) }
        }

        var bodyPitch = pitch.x
        var framing = 0.0
        if let kind = oneShotKind {
            let total = kind == .wave ? tuning.robotWaveSeconds : tuning.robotFlipSeconds
            let progress = total > 0 ? (time - oneShotStart) / total : 1
            if progress >= 1 {
                oneShotKind = nil
            } else if kind == .wave {
                applyWave(progress: progress, total: total, angles: &angles, pitch: &bodyPitch)
            } else {
                applyFlip(progress: progress, angles: &angles, lift: &bodyLift, pitch: &bodyPitch)
                framing = Self.smooth(progress / Self.flipFramingRamp) * (1 - Self.smooth((progress - (1 - Self.flipFramingRamp)) / Self.flipFramingRamp))
            }
        }
        return Pose(angles: angles, bodyLift: bodyLift, bodyPitch: bodyPitch, bodyRoll: roll.x, bodyYaw: yaw.x, framing: framing)
    }

    private static func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }

    /// Weight shifts back, the front-right paw lifts forward and waves, then it settles.
    private func applyWave(progress: Double, total: Double, angles: inout [JointID: Double], pitch: inout Double) {
        let deg = Double.pi / 180
        let envelope = Self.smooth(progress / 0.2) * (1 - Self.smooth((progress - 0.8) / 0.2))
        let hipID = JointID(kind: .hip, leg: .FR), kneeID = JointID(kind: .knee, leg: .FR), ankleID = JointID(kind: .ankle, leg: .FR)
        let kneeMax = tuning.frontKneeMaxDeg * deg
        let hip = -Self.waveHipDeg * deg * envelope   // negative swings the foot forward
        // The knee runs the full front limit; the hip wobbles a little too so the paw reads as waving.
        let phase = 2 * Double.pi * Self.waveCount * ((progress - 0.2) / 0.6)
        let wave = progress >= 0.2 && progress <= 0.8 ? sin(phase) : 0
        let knee = kneeMax * wave * envelope
        angles[hipID] = hip + 8 * deg * wave * envelope
        angles[kneeID] = min(max(knee, -kneeMax), kneeMax)
        angles[ankleID] = -((angles[hipID] ?? 0) + knee) * Self.waveWristFactor
        pitch += -Self.waveBodyPitchDeg * deg * envelope
    }

    /// Crouch, hop, a full backward pitch roll with every leg tucked, land, settle.
    private func applyFlip(progress p: Double, angles: inout [JointID: Double], lift: inout Double, pitch: inout Double) {
        let deg = Double.pi / 180
        let air = max(0, min(1, (p - Self.flipTakeoff) / (Self.flipLand - Self.flipTakeoff)))
        var l = 0.0
        if p < Self.flipCrouchEnd { l = Self.flipCrouchMeters * Self.smooth(p / Self.flipCrouchEnd) }
        else if p < Self.flipTakeoff {
            l = Self.flipCrouchMeters + (Self.flipLiftMeters * 0.1 - Self.flipCrouchMeters) * Self.smooth((p - Self.flipCrouchEnd) / (Self.flipTakeoff - Self.flipCrouchEnd))
        } else if p < Self.flipLand {
            l = Self.flipLiftMeters * (0.1 + 0.9 * 4 * air * (1 - air))
        } else if p < Self.flipSettle {
            let f = Self.smooth((p - Self.flipLand) / (Self.flipSettle - Self.flipLand))
            l = Self.flipLiftMeters * 0.1 * (1 - f) + Self.flipCrouchMeters * f
        } else {
            l = Self.flipCrouchMeters * (1 - Self.smooth((p - Self.flipSettle) / (1 - Self.flipSettle)))
        }
        lift += l
        // Driven directly (not through the pitch spring) so 2 pi does not unwind.
        if air < 1 { pitch += -2 * Double.pi * Self.smooth(air) }   // 2 pi is upright again; hand back at the top of the landing
        let tuck = Self.smooth((p - Self.flipCrouchEnd) / 0.12) * (1 - Self.smooth((p - Self.flipLand) / 0.08))
        for leg in Leg.allCases {
            let kneeMax = leg.isFront ? tuning.frontKneeMaxDeg * deg : tuning.backKneeMaxDeg * deg
            let hipDir = leg.isFront ? -1.0 : 1.0
            let hipID = JointID(kind: .hip, leg: leg), kneeID = JointID(kind: .knee, leg: leg), ankleID = JointID(kind: .ankle, leg: leg)
            let hip = (angles[hipID] ?? 0) * (1 - tuck) + hipDir * Self.flipTuckHipDeg * deg * tuck
            let knee = (angles[kneeID] ?? 0) * (1 - tuck) + kneeMax * tuck
            angles[hipID] = hip; angles[kneeID] = knee
            angles[ankleID] = -(hip + knee) * Self.ankleFactor
        }
    }

    private static func celebrationLift(_ progress: Double) -> Double {
        let c = celebrationCurve
        for i in 1..<c.count where progress <= c[i].t {
            let f = (progress - c[i - 1].t) / (c[i].t - c[i - 1].t)
            let eased = f * f * (3 - 2 * f)
            return c[i - 1].lift + (c[i].lift - c[i - 1].lift) * eased
        }
        return 0
    }
}
