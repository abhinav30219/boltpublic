import XCTest
@testable import BoltCore

final class RobotTwinTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let tuning = CompanionTuning()

    // MARK: parsing
    func testParsesTextCommands() {
        XCTAssertEqual(RobotMotionCommand(.stand), .stand)
        XCTAssertEqual(RobotMotionCommand(.rest), .rest)
        XCTAssertEqual(RobotMotionCommand(.walkForward(cycles: 3)), .walk(forward: true, cycles: 3))
        XCTAssertEqual(RobotMotionCommand(.walkBackward(cycles: 2)), .walk(forward: false, cycles: 2))
        XCTAssertEqual(RobotMotionCommand(.text("  kup \n")), .stand)
        XCTAssertEqual(RobotMotionCommand(.text("kwkF 5")), .walk(forward: true, cycles: 5))
    }

    func testWalkCycleCountDefaultsToOne() {
        XCTAssertEqual(RobotMotionCommand(.text("kwkF")), .walk(forward: true, cycles: 1))
        XCTAssertEqual(RobotMotionCommand(.text("kwkB abc")), .walk(forward: false, cycles: 1))
        XCTAssertEqual(RobotMotionCommand(.text("kwkF 0")), .walk(forward: true, cycles: 1))
        XCTAssertEqual(RobotMotionCommand(.text("kwkB -4")), .walk(forward: false, cycles: 1))
    }

    func testParsesGazePacket() {
        XCTAssertEqual(RobotMotionCommand(.gaze(x: -128, y: 127)), .gaze(x: -128, y: 127))
        XCTAssertEqual(RobotMotionCommand(.binary([0x4A, 0x72, 5, 0xFB, 0x7E])), .gaze(x: 5, y: -5))
    }

    func testIgnoresOtherCommands() {
        XCTAssertNil(RobotMotionCommand(.queryWiFi))
        XCTAssertNil(RobotMotionCommand(.text("kupx")))
        XCTAssertNil(RobotMotionCommand(.text("")))
        XCTAssertNil(RobotMotionCommand(.joints([(joint: 1, angle: 10)])))
        XCTAssertNil(RobotMotionCommand(.binary([0x4A, 0x72, 1, 0x7E])))
        XCTAssertNil(RobotMotionCommand(.binary([0x4A, 0x72, 1, 2, 0x00])))
    }

    // MARK: twin
    func testStartsStandingIdle() {
        let b = RobotTwin().body(at: t0)
        XCTAssertEqual(b.motion, .idle)
        XCTAssertNil(b.gaze)
    }

    func testWalkThreeCyclesEndsAtThreePointSixSeconds() {
        var twin = RobotTwin()
        twin.apply(.walk(forward: true, cycles: 3), at: t0, tuning: tuning)
        let mid = twin.body(at: t0.addingTimeInterval(3.5))
        XCTAssertEqual(mid.motion, .walk)
        XCTAssertTrue(mid.forward)
        XCTAssertEqual(mid.cadence, 100)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(3.7)).motion, .idle)
    }

    func testBackwardWalk() {
        var twin = RobotTwin()
        twin.apply(.walk(forward: false, cycles: 1), at: t0, tuning: tuning)
        let b = twin.body(at: t0.addingTimeInterval(0.5))
        XCTAssertEqual(b.motion, .walk)
        XCTAssertFalse(b.forward)
    }

    func testRestPersistsAndStandClears() {
        var twin = RobotTwin()
        twin.apply(.rest, at: t0, tuning: tuning)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(1000)).motion, .sleep)
        twin.apply(.stand, at: t0.addingTimeInterval(1001), tuning: tuning)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(1002)).motion, .idle)
    }

    func testGazeMapsAndPersistsUntilStandOrRest() {
        var twin = RobotTwin()
        twin.apply(.gaze(x: 127, y: -128), at: t0, tuning: tuning)
        let g = twin.body(at: t0.addingTimeInterval(60)).gaze
        XCTAssertEqual(g?.yawDeg ?? .nan, 20, accuracy: 1e-9)
        XCTAssertEqual(g?.pitchDeg ?? .nan, -10 * 128.0 / 127.0, accuracy: 1e-9)
        twin.apply(.gaze(x: 0, y: 0), at: t0, tuning: tuning)
        XCTAssertEqual(twin.body(at: t0).gaze?.yawDeg ?? .nan, 0, accuracy: 1e-9)
        twin.apply(.stand, at: t0, tuning: tuning)
        XCTAssertNil(twin.body(at: t0).gaze)
        twin.apply(.gaze(x: 10, y: 10), at: t0, tuning: tuning)
        twin.apply(.rest, at: t0, tuning: tuning)
        XCTAssertNil(twin.body(at: t0).gaze)
    }

    func testGazeKeepsCurrentMotionAndWalkKeepsGaze() {
        var twin = RobotTwin()
        twin.apply(.rest, at: t0, tuning: tuning)
        twin.apply(.gaze(x: 50, y: 0), at: t0, tuning: tuning)
        XCTAssertEqual(twin.body(at: t0).motion, .sleep)
    }

    func testNewCommandReplacesWalk() {
        var twin = RobotTwin()
        twin.apply(.walk(forward: true, cycles: 10), at: t0, tuning: tuning)
        twin.apply(.walk(forward: false, cycles: 1), at: t0.addingTimeInterval(1), tuning: tuning)
        XCTAssertFalse(twin.body(at: t0.addingTimeInterval(1.5)).forward)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(2.4)).motion, .idle)   // 1 + 1.2 = 2.2
        twin.apply(.walk(forward: true, cycles: 10), at: t0.addingTimeInterval(3), tuning: tuning)
        twin.apply(.stand, at: t0.addingTimeInterval(4), tuning: tuning)
        XCTAssertEqual(twin.body(at: t0.addingTimeInterval(5)).motion, .idle)
    }

    func testTuningDefaultsAndDecode() throws {
        let t = CompanionTuning()
        XCTAssertEqual(t.robotWalkCycleSeconds, 1.2)
        XCTAssertEqual(t.robotWalkCadence, 100)
        XCTAssertEqual(t.robotGazeMaxYawDeg, 20)
        XCTAssertEqual(t.robotGazeMaxPitchDeg, 10)
        let d = try JSONDecoder().decode(CompanionTuning.self, from: Data(#"{"robotWalkCadence": 80}"#.utf8))
        XCTAssertEqual(d.robotWalkCadence, 80)
        XCTAssertEqual(d.robotWalkCycleSeconds, 1.2)
    }
}
