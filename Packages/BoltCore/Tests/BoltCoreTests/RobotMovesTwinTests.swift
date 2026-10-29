import XCTest
@testable import BoltCore

final class RobotMovesTwinTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let tuning = CompanionTuning()
    private let cfg = RobotMoveConfig.defaults
    private let dt = 1.0 / 60
    private func r(_ s: String, _ c: RobotMoveConfig? = nil) -> RobotMotionCommand? {
        RobotMotionCommand.resolve(.text(s), moves: c ?? cfg)
    }
    private func deg(_ rad: Double) -> Double { rad * 180 / .pi }
    private var idle: CompanionState { var s = CompanionState(); s.motion = .idle; s.mood = .neutral; return s }

    // MARK: resolve
    func testResolvesEveryDefaultMove() {
        XCTAssertEqual(r("kup"), .stand)
        XCTAssertEqual(r("krest"), .rest)
        XCTAssertEqual(r("khi"), .wave)
        XCTAssertEqual(r("kflipRoll"), .flip)
        XCTAssertEqual(r("kstep1F"), .walkUntilStop(forward: true, maxSeconds: 3))
        XCTAssertEqual(r("kwkF 3"), .walk(forward: true, cycles: 3))
        XCTAssertEqual(r("kbkF 2"), .walk(forward: false, cycles: 2))
        for m in cfg.moves {
            XCTAssertNotNil(RobotMotionCommand.resolve(m.robotCommand, moves: cfg), m.id)
        }
    }

    func testEditedTextStillMapsById() {
        var c = cfg
        c.moves[c.moves.firstIndex { $0.id == RobotMove.Key.wave }!].command = "kwh"
        c.moves[c.moves.firstIndex { $0.id == RobotMove.Key.doubleTap }!].command = "kbf"
        var i = c.moves.firstIndex { $0.id == RobotMove.Key.walkSteps }!
        c.moves[i].command = "ktrF"; c.moves[i].count = 5
        i = c.moves.firstIndex { $0.id == RobotMove.Key.walkForward }!
        c.moves[i].command = "kcrF"; c.moves[i].seconds = 2
        XCTAssertEqual(r("kwh", c), .wave)
        XCTAssertEqual(r("kbf", c), .flip)
        XCTAssertEqual(r("ktrF 5", c), .walk(forward: true, cycles: 5))
        XCTAssertEqual(r("kcrF", c), .walkUntilStop(forward: true, maxSeconds: 2))
        XCTAssertNil(r("khi", c))   // no longer a move, no literal meaning
    }

    func testStopCommandIsStand() {
        var c = cfg
        c.stop = "d"
        XCTAssertEqual(r("d", c), .stand)
        XCTAssertEqual(r("  kup\n"), .stand)
    }

    func testFallbackLiteralParseAndCustomMoves() {
        XCTAssertEqual(r("kwkB 4"), .walk(forward: false, cycles: 4))
        XCTAssertEqual(r("kbkF 3"), .walk(forward: false, cycles: 3))
        XCTAssertNil(r("ksit"))
        XCTAssertNil(RobotMotionCommand.resolve(.queryWiFi, moves: cfg))
        XCTAssertEqual(RobotMotionCommand.resolve(.gaze(x: 1, y: 2), moves: cfg), .gaze(x: 1, y: 2))
        var c = cfg
        c.moves.append(RobotMove(id: "x", title: "Custom", command: "krest"))
        c.moves.append(RobotMove(id: "y", title: "Odd", command: "kjmp"))
        XCTAssertEqual(r("krest", c), .rest)
        XCTAssertNil(r("kjmp", c))
    }

    // MARK: twin
    func testTimedWalkLastsUntilStopAndCapsAtSeconds() {
        var twin = RobotTwin()
        twin.apply(r("kstep1F")!, at: t0, tuning: tuning)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(2.9)).motion, .walk)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(3.1)).motion, .idle)   // safety cap
        twin.apply(r("kstep1F")!, at: t0, tuning: tuning)
        twin.apply(r("kup")!, at: t0.addingTimeInterval(1), tuning: tuning)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(1.1)).motion, .idle)
    }

    func testOneShotsExposedForTheirDuration() {
        var twin = RobotTwin()
        twin.apply(.wave, at: t0, tuning: tuning)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(1.0)).oneShot, .init(kind: .wave, startedAt: t0))
        XCTAssertNil(twin.body(at: t0.addingTimeInterval(1.6)).oneShot)
        twin.apply(.flip, at: t0, tuning: tuning)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(1.1)).oneShot?.kind, .flip)
        XCTAssertNil(twin.body(at: t0.addingTimeInterval(1.3)).oneShot)
    }

    func testTuningDefaults() throws {
        XCTAssertEqual(CompanionTuning().robotWaveSeconds, 1.5)
        XCTAssertEqual(CompanionTuning().robotFlipSeconds, 1.2)
        let d = try JSONDecoder().decode(CompanionTuning.self, from: Data(#"{"robotFlipSeconds": 2}"#.utf8))
        XCTAssertEqual(d.robotFlipSeconds, 2)
        XCTAssertEqual(d.robotWaveSeconds, 1.5)
    }

    // MARK: solver
    private func run(_ kind: PoseSolver.OneShot, seconds: Double, extra: Double = 1.5, _ each: (Double, Pose) -> Void) {
        var s = PoseSolver()
        for _ in 0..<60 { _ = s.step(state: idle, dt: dt) }
        s.play(kind)
        var t = 0.0
        while t < seconds + extra {
            let p = s.step(state: idle, dt: dt); t += dt
            each(t, p)
        }
    }

    private func checkLimits(_ p: Pose, _ msg: String) {
        for leg in Leg.allCases {
            let k = deg(p.angles[JointID(kind: .knee, leg: leg)] ?? .nan)
            if leg.isFront { XCTAssertLessThanOrEqual(abs(k), 25 + 1e-9, msg) }
            else { XCTAssertGreaterThanOrEqual(k, -1e-9, msg); XCTAssertLessThanOrEqual(k, 60 + 1e-9, msg) }
        }
    }

    func testWaveRaisesFrontRightAndOscillatesWithinLimits() {
        var minHip = 0.0, kneeCrossings = 0, prev = 0.0
        var lastWaveT = 0.0
        run(.wave, seconds: 1.5) { t, p in
            self.checkLimits(p, "wave")
            let h = self.deg(p.angles[JointID(kind: .hip, leg: .FR)] ?? 0)
            minHip = min(minHip, h)
            let k = self.deg(p.angles[JointID(kind: .knee, leg: .FR)] ?? 0)
            if t < 1.5 { if prev < 0 && k >= 0 || prev > 0 && k <= 0 { kneeCrossings += 1 }; prev = k }
            if abs(k) > 3 { lastWaveT = t }
            XCTAssertEqual(self.deg(p.angles[JointID(kind: .hip, leg: .FL)] ?? 0), 0, accuracy: 1, "FL stays")
        }
        XCTAssertLessThan(minHip, -40)
        XCTAssertGreaterThanOrEqual(kneeCrossings, 5)   // about 3 waves
        XCTAssertLessThanOrEqual(lastWaveT, 1.6)
    }

    func testWaveSettlesToRest() {
        var last: Pose?
        var solver = PoseSolver(); solver.idleLife = false
        for _ in 0..<60 { _ = solver.step(state: idle, dt: dt) }
        solver.play(.wave)
        for _ in 0..<(60 * 3) { last = solver.step(state: idle, dt: dt) }
        XCTAssertEqual(deg(last!.angles[JointID(kind: .hip, leg: .FR)]!), 0, accuracy: 0.5)
        XCTAssertEqual(deg(last!.angles[JointID(kind: .knee, leg: .FR)]!), 0, accuracy: 0.5)
    }

    func testFlipRotatesFullTurnLiftsAndLandsUpright() {
        var maxLift = 0.0, maxPitch = 0.0, minPitch = 0.0, last: Pose?
        run(.flip, seconds: 1.2, extra: 1.5) { t, p in
            self.checkLimits(p, "flip")
            maxLift = max(maxLift, p.bodyLift)
            maxPitch = max(maxPitch, p.bodyPitch); minPitch = min(minPitch, p.bodyPitch)
            if t > 1.3 { XCTAssertLessThan(abs(p.bodyPitch), 0.2, "upright after \(t)") }
            last = p
        }
        XCTAssertGreaterThan(max(maxPitch, -minPitch), 2 * Double.pi - 0.15)
        XCTAssertLessThan(max(maxPitch, -minPitch), 2 * Double.pi + 0.3)
        XCTAssertGreaterThanOrEqual(maxLift, 0.15)
        XCTAssertLessThan(maxLift, 0.25)
        XCTAssertEqual(last!.bodyLift, 0, accuracy: 0.01)
        XCTAssertEqual(last!.bodyPitch, 0, accuracy: 0.01)
    }

    func testFlipFramingEasesInPeaksAndEasesBackToZero() {
        var peak = 0.0, maxStep = 0.0, prev = 0.0, midpoint = 0.0
        run(.flip, seconds: 1.2, extra: 1.0) { t, p in
            XCTAssertTrue((0 ... 1).contains(p.framing), "framing \(p.framing) at \(t)")
            peak = max(peak, p.framing); maxStep = max(maxStep, abs(p.framing - prev)); prev = p.framing
            if abs(t - 0.6) < 0.01 { midpoint = p.framing }
            if t > 1.25 { XCTAssertEqual(p.framing, 0, accuracy: 1e-9, "settled at \(t)") }
        }
        XCTAssertEqual(peak, 1, accuracy: 1e-9)
        XCTAssertEqual(midpoint, 1, accuracy: 1e-9)
        XCTAssertLessThan(maxStep, 0.2)   // eased: no jump between 1/60 s frames
        var solver = PoseSolver(); solver.idleLife = false
        XCTAssertEqual(solver.step(state: idle, dt: dt).framing, 0)
        XCTAssertEqual(Pose.rest.framing, 0)
    }

    func testFlipPitchHasNoSnapsAndDurationFollowsTuning() {
        var prev = 0.0, maxStep = 0.0
        run(.flip, seconds: 1.2) { _, p in var d = abs(p.bodyPitch - prev).truncatingRemainder(dividingBy: 2 * .pi)
            d = min(d, 2 * .pi - d)   // the hand-back from 2 pi to 0 is the same orientation
            maxStep = max(maxStep, d); prev = p.bodyPitch }
        XCTAssertLessThan(maxStep, 0.4)   // rad per 1/60 s frame; the final 2 pi -> 0 hand-back is not a step
        var t = CompanionTuning(); t.robotFlipSeconds = 3
        var s = PoseSolver(tuning: t)
        s.play(.flip)
        var maxLift = 0.0
        for _ in 0..<(60 * 2) { maxLift = max(maxLift, s.step(state: idle, dt: dt).bodyLift) }
        XCTAssertGreaterThan(maxLift, 0.15)
    }
}
