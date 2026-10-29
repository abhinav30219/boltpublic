import XCTest
@testable import BoltCore

final class MetricMeaningTests: XCTestCase {
    func testHeart() {
        XCTAssertEqual(MetricMeaning.heart(150, baseline: 65), Meaning(word: "Check", isAlert: true))
        XCTAssertEqual(MetricMeaning.heart(90, baseline: 65).word, "Busy")
        XCTAssertFalse(MetricMeaning.heart(90, baseline: 65).isAlert)
        XCTAssertEqual(MetricMeaning.heart(89.9, baseline: 65).word, "Calm")
        XCTAssertEqual(MetricMeaning.heart(120, baseline: nil).word, "Calm")
        XCTAssertEqual(MetricMeaning.heart(150, baseline: nil).word, "Check")
    }

    func testHeartUsesConfig() {
        var t = CompanionTuning(); t.meaningBusyAboveBaselineBpm = 10
        XCTAssertEqual(MetricMeaning.heart(75, baseline: 65, tuning: t).word, "Busy")
        var s = TriggerConfig(); s.safetyHRAtRest = 100
        XCTAssertTrue(MetricMeaning.heart(100, baseline: 65, safety: s).isAlert)
    }

    func testSteps() {
        XCTAssertEqual(MetricMeaning.steps(8000, goal: 8000).word, "Goal met")
        XCTAssertEqual(MetricMeaning.steps(4000, goal: 8000).word, "Good day")
        XCTAssertEqual(MetricMeaning.steps(3999, goal: 8000).word, "Getting going")
    }

    func testEnergy() {
        XCTAssertEqual(MetricMeaning.energy(100).word, "Active")
        XCTAssertEqual(MetricMeaning.energy(99.9).word, "Easy day")
        var t = CompanionTuning(); t.meaningActiveKcal = 50
        XCTAssertEqual(MetricMeaning.energy(50, tuning: t).word, "Active")
    }

    func testRelaxation() {
        XCTAssertEqual(MetricMeaning.relaxation(85, baseline: 100).word, "Rested")
        XCTAssertEqual(MetricMeaning.relaxation(84.9, baseline: 100).word, "Low")
        XCTAssertEqual(MetricMeaning.relaxation(10, baseline: nil).word, "Rested")
        var t = CompanionTuning(); t.meaningRestedFractionOfBaseline = 0.5
        XCTAssertEqual(MetricMeaning.relaxation(50, baseline: 100, tuning: t).word, "Rested")
    }

    func testOxygen() {
        XCTAssertEqual(MetricMeaning.oxygen(89.9), Meaning(word: "Check", isAlert: true))
        XCTAssertEqual(MetricMeaning.oxygen(90).word, "Low")
        XCTAssertEqual(MetricMeaning.oxygen(94.9).word, "Low")
        XCTAssertEqual(MetricMeaning.oxygen(95).word, "Normal")
        var t = CompanionTuning(); t.meaningOxygenLowPct = 97
        XCTAssertEqual(MetricMeaning.oxygen(96, tuning: t).word, "Low")
        var s = TriggerConfig(); s.safetySpO2 = 92
        XCTAssertTrue(MetricMeaning.oxygen(91, safety: s).isAlert)
    }

    func testSkinTemp() {
        XCTAssertEqual(MetricMeaning.skinTemp(33.5, baseline: 33, shift: 0.5).word, "Steady")
        XCTAssertEqual(MetricMeaning.skinTemp(33.6, baseline: 33, shift: 0.5).word, "Warmer")
        XCTAssertEqual(MetricMeaning.skinTemp(32.4, baseline: 33, shift: 0.5).word, "Cooler")
        XCTAssertEqual(MetricMeaning.skinTemp(40, baseline: nil, shift: 0.5).word, "Steady")
    }
}
