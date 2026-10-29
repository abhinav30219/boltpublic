import XCTest
@testable import BoltCore

final class PoseSolverTests: XCTestCase {
    private let dt = 1.0 / 30
    private func state(_ motion: CompanionMotion, _ mood: CompanionMood = .neutral, cadence: Double = 0) -> CompanionState {
        var s = CompanionState()
        s.motion = motion; s.mood = mood; s.cadence = cadence
        return s
    }
    private func deg(_ rad: Double) -> Double { rad * 180 / .pi }
    private func hip(_ p: Pose, _ leg: Leg) -> Double { p.angles[JointID(kind: .hip, leg: leg)] ?? .nan }

    func testJointLimitsHoldForAllStates() {
        let motions: [CompanionMotion] = [.idle, .walk, .trot, .sleep]
        let moods: [CompanionMood] = [.neutral, .happy, .calm, .tired, .concerned, .determined, .relieved, .scanning, .sleeping]
        for motion in motions {
            for mood in moods {
                var solver = PoseSolver()
                for frame in 0..<600 {
                    let cadence = 200.0 * Double(frame) / 599
                    let pose = solver.step(state: state(motion, mood, cadence: cadence), dt: dt)
                    for leg in Leg.allCases {
                        let knee = deg(pose.angles[JointID(kind: .knee, leg: leg)] ?? .nan)
                        if leg.isFront {
                            XCTAssertLessThanOrEqual(abs(knee), 25 + 1e-9, "\(motion) \(mood) \(leg)")
                        } else {
                            XCTAssertGreaterThanOrEqual(knee, -1e-9, "\(motion) \(mood) \(leg)")
                            XCTAssertLessThanOrEqual(knee, 60 + 1e-9, "\(motion) \(mood) \(leg)")
                        }
                    }
                }
            }
        }
    }

    /// Per-frame |change| of hip_FL for `frames` frames, after running `warmup` frames first.
    private func hipSteps(_ solver: inout PoseSolver, _ s: CompanionState, frames: Int) -> Double {
        var last = deg(hip(solver.step(state: s, dt: dt), .FL))
        var maxStep = 0.0
        for _ in 0..<frames {
            let h = deg(hip(solver.step(state: s, dt: dt), .FL))
            maxStep = max(maxStep, abs(h - last)); last = h
        }
        return maxStep
    }

    func testGaitPhaseContinuousAcrossCadenceChange() {
        var steady = PoseSolver()
        for _ in 0..<60 { _ = steady.step(state: state(.walk, cadence: 160), dt: dt) }
        let steadyMax = hipSteps(&steady, state(.walk, cadence: 160), frames: 15)

        var solver = PoseSolver()
        for _ in 0..<60 { _ = solver.step(state: state(.walk, cadence: 100), dt: dt) }
        let phaseBefore = solver.gaitPhase
        let switched = hipSteps(&solver, state(.walk, cadence: 160), frames: 15)
        XCTAssertGreaterThan(solver.gaitPhase, phaseBefore)   // never reset
        XCTAssertLessThanOrEqual(switched, 1.25 * steadyMax)
    }

    func testWalkSwingAmplitude() {
        for (motion, amp) in [(CompanionMotion.walk, 20.0), (.trot, 30.0)] {
            var solver = PoseSolver()
            let s = state(motion, cadence: 100)
            for _ in 0..<60 { _ = solver.step(state: s, dt: dt) }
            var peak = 0.0
            for _ in 0..<30 { peak = max(peak, abs(deg(hip(solver.step(state: s, dt: dt), .FL)))) }
            XCTAssertGreaterThanOrEqual(peak, 0.8 * amp, "\(motion)")
        }
    }

    func testDiagonalPairsMoveTogether() {
        var solver = PoseSolver()
        var pose = Pose.rest
        for frame in 0..<60 { pose = solver.step(state: state(.walk, cadence: 100), dt: dt); _ = frame }
        for _ in 0..<30 {
            pose = solver.step(state: state(.walk, cadence: 100), dt: dt)
            XCTAssertEqual(deg(hip(pose, .FL)), deg(hip(pose, .BR)), accuracy: 1)
            XCTAssertEqual(deg(hip(pose, .FL)), -deg(hip(pose, .FR)), accuracy: 1)
            XCTAssertEqual(deg(hip(pose, .FR)), deg(hip(pose, .BL)), accuracy: 1)
        }
    }

    func testDeterministic() {
        var a = PoseSolver(seed: 5), b = PoseSolver(seed: 5)
        for frame in 0..<900 {
            let s = frame < 450 ? state(.idle) : state(.trot, .happy, cadence: 150)
            XCTAssertEqual(a.step(state: s, dt: dt), b.step(state: s, dt: dt))
        }
    }

    func testIdleHasNoLegSwing() {
        var solver = PoseSolver()
        for _ in 0..<(30 * 5) {
            let pose = solver.step(state: state(.idle), dt: dt)
            for leg in Leg.allCases { XCTAssertLessThan(abs(deg(hip(pose, leg))), 2) }
        }
    }

    func testCelebrateReturnsToBaseline() {
        var a = PoseSolver(), b = PoseSolver()
        let s = state(.idle)
        for _ in 0..<30 { _ = a.step(state: s, dt: dt); _ = b.step(state: s, dt: dt) }
        a.celebrate()
        var peak = 0.0
        var pa = Pose.rest, pb = Pose.rest
        for _ in 0..<45 {
            pa = a.step(state: s, dt: dt); pb = b.step(state: s, dt: dt)
            peak = max(peak, pa.bodyLift - pb.bodyLift)
        }
        XCTAssertGreaterThan(peak, 0.02)
        XCTAssertEqual(pa.bodyLift, pb.bodyLift, accuracy: 0.003)
    }
}

final class PoseSolverTwinTests: XCTestCase {
    private let dt = 1.0 / 30
    private func walking() -> CompanionState {
        var s = CompanionState(); s.motion = .walk; s.mood = .neutral; s.cadence = 100; return s
    }
    private func hipFL(_ p: Pose) -> Double { p.angles[JointID(kind: .hip, leg: .FL)] ?? .nan }

    func testReverseGaitSwingsOppositeDirection() {
        var fwd = PoseSolver(), back = PoseSolver()
        back.walkForward = false
        var f = [Double](), b = [Double]()
        for _ in 0..<60 {
            f.append(hipFL(fwd.step(state: walking(), dt: dt)))
            b.append(hipFL(back.step(state: walking(), dt: dt)))
        }
        XCTAssertLessThan(back.gaitPhase, 0)
        XCTAssertGreaterThan(fwd.gaitPhase, 0)
        XCTAssertEqual(fwd.gaitPhase, -back.gaitPhase, accuracy: 1e-9)
        // sin is odd, so mirrored phase gives mirrored hip angle
        for i in 0..<60 { XCTAssertEqual(f[i], -b[i], accuracy: 1e-9) }
    }

    func testGazeSetsBodyYawAndPitchTargets() {
        var solver = PoseSolver()
        solver.gaze = PoseGaze(yawDeg: 15, pitchDeg: -6)
        var pose = Pose.rest
        for _ in 0..<150 { pose = solver.step(state: CompanionState(), dt: dt) }
        XCTAssertEqual(pose.bodyYaw * 180 / .pi, 15, accuracy: 0.05)
        XCTAssertEqual(pose.bodyPitch * 180 / .pi, -6, accuracy: 0.05)
    }

    func testGazeReplacesIdleLookAround() {
        var idle = CompanionState(); idle.motion = .idle
        var solver = PoseSolver()
        solver.gaze = PoseGaze(yawDeg: 0, pitchDeg: 0)
        for _ in 0..<1500 {   // 50 s: random looks would have moved yaw
            let p = solver.step(state: idle, dt: dt)
            XCTAssertEqual(p.bodyYaw, 0, accuracy: 1e-9)
        }
    }
}
