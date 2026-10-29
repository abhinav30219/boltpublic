import XCTest
@testable import BoltCore

final class IdleLifeTests: XCTestCase {
    private let dt = 1.0 / 30
    private func st(_ m: CompanionMotion) -> CompanionState {
        var s = CompanionState(); s.motion = m; s.mood = m == .sleep ? .sleeping : .neutral; return s
    }
    private func deg(_ r: Double) -> Double { r * 180 / .pi }

    func testDeterministicForSameSeed() {
        var a = PoseSolver(seed: 7), b = PoseSolver(seed: 7), c = PoseSolver(seed: 8)
        var differs = false
        for _ in 0..<900 {
            let pa = a.step(state: st(.idle), dt: dt), pb = b.step(state: st(.idle), dt: dt), pc = c.step(state: st(.idle), dt: dt)
            XCTAssertEqual(pa, pb)
            if pa != pc { differs = true }
        }
        XCTAssertTrue(differs)
    }

    func testJointLimitsHoldOverSixtySecondsOfIdle() {
        for seed in 1...5 as ClosedRange<UInt64> {
            var s = PoseSolver(seed: seed)
            var maxRoll = 0.0, maxPitch = 0.0
            for _ in 0..<(60 * 30) {
                let p = s.step(state: st(.idle), dt: dt)
                maxRoll = max(maxRoll, abs(deg(p.bodyRoll))); maxPitch = max(maxPitch, abs(deg(p.bodyPitch)))
                for leg in Leg.allCases {
                    let k = deg(p.angles[JointID(kind: .knee, leg: leg)] ?? .nan)
                    if leg.isFront { XCTAssertLessThanOrEqual(abs(k), 25 + 1e-9) }
                    else { XCTAssertGreaterThanOrEqual(k, -1e-9); XCTAssertLessThanOrEqual(k, 60 + 1e-9) }
                }
            }
            XCTAssertLessThan(maxRoll, 4.5)
            XCTAssertLessThan(maxPitch, 6)
        }
    }

    func testSwayAndFidgetsHappen() {
        var s = PoseSolver(seed: 3)
        var maxRoll = 0.0
        for _ in 0..<(15 * 30) { maxRoll = max(maxRoll, abs(deg(s.step(state: st(.idle), dt: dt).bodyRoll))) }
        XCTAssertGreaterThanOrEqual(s.idleFidgetCount, 1)
        XCTAssertGreaterThan(maxRoll, 1.5)
    }

    func testNoFidgetsWhileWalkingOrResting() {
        for motion in [CompanionMotion.walk, .trot, .sleep] {
            var s = PoseSolver(seed: 3)
            for _ in 0..<(60 * 30) { _ = s.step(state: st(motion), dt: dt) }
            XCTAssertEqual(s.idleFidgetCount, 0, "\(motion)")
        }
        var s = PoseSolver(seed: 3)
        s.idleLife = false
        for _ in 0..<(60 * 30) { _ = s.step(state: st(.idle), dt: dt) }
        XCTAssertEqual(s.idleFidgetCount, 0)
    }

    func testNoFidgetDuringOneShots() {
        var s = PoseSolver(seed: 3)
        for _ in 0..<(5 * 30) { _ = s.step(state: st(.idle), dt: dt) }
        let before = s.idleFidgetCount
        s.play(.wave)
        for _ in 0..<(Int(1.5 * 30)) { _ = s.step(state: st(.idle), dt: dt) }
        XCTAssertEqual(s.idleFidgetCount, before)
    }

    func testIdleToWalkSwitchIsSmooth() {
        for seed in 1...8 as ClosedRange<UInt64> {
            var s = PoseSolver(seed: seed)
            var prev = s.step(state: st(.idle), dt: dt)
            for f in 1..<(40 * 30) {
                let motion: CompanionMotion = f >= 20 * 30 ? .walk : .idle
                let p = s.step(state: st(motion), dt: dt)
                if f >= 18 * 30 && f < 20 * 30 + 15 {   // the gait itself steps more than 3 degrees once built up
                    for (id, a) in p.angles { XCTAssertLessThanOrEqual(abs(deg(a - (prev.angles[id] ?? 0))), 3, "seed \(seed) frame \(f) \(id)") }
                }
                prev = p
            }
        }
    }

    func testTuningDefaultsAndDecode() throws {
        let t = CompanionTuning()
        XCTAssertEqual([t.idleSwayDeg, t.idleFidgetMinSeconds, t.idleFidgetMaxSeconds, t.idleLookPitchDeg], [3.5, 6, 12, 5])
        let d = try JSONDecoder().decode(CompanionTuning.self, from: Data(#"{"idleSwayDeg": 1}"#.utf8))
        XCTAssertEqual(d.idleSwayDeg, 1); XCTAssertEqual(d.idleFidgetMaxSeconds, 12)
    }
}
