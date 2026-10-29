import XCTest
@testable import BoltCore

final class TuningTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tuning-\(UUID().uuidString).json")
    }

    func testDefaultsMatchSpec() {
        let t = Tuning()
        XCTAssertEqual(t.fall.responseTimeoutSeconds, 30)
        XCTAssertEqual(t.companion.dailyStepGoal, 8000)
        XCTAssertEqual(t.companion.milestoneSteps, 1000)
        XCTAssertEqual(t.render.visibleFPS, 30)
        XCTAssertEqual(t.render.generatingFPS, 20)
        XCTAssertEqual(t.companion.meaningBusyAboveBaselineBpm, 25)
        XCTAssertEqual(t.companion.meaningRestedFractionOfBaseline, 0.85)
        XCTAssertEqual(t.fall.emergencyNumber, "911")
    }

    func testRoundTrip() throws {
        var t = Tuning()
        t.companion.dailyStepGoal = 10_000
        t.fall.cooldownSeconds = 90
        t.render.reduceAnimation = true
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try t.save(to: url)
        let loaded = Tuning.load(from: url)
        XCTAssertEqual(loaded.tuning, t)
        XCTAssertNil(loaded.error)
    }

    func testMissingKeysFallBackToDefaults() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"fall":{"responseTimeoutSeconds":45}}"#.utf8).write(to: url)
        let loaded = Tuning.load(from: url)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.tuning.fall.responseTimeoutSeconds, 45)
        XCTAssertEqual(loaded.tuning.fall.cooldownSeconds, 120)
        XCTAssertEqual(loaded.tuning.companion, CompanionTuning())
    }

    func testOldFallKeysAreIgnored() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"fall":{"impactG":3,"freeFallG":0.4,"stillSeconds":9,"responseTimeoutSeconds":40}}"#.utf8).write(to: url)
        let loaded = Tuning.load(from: url)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.tuning.fall.responseTimeoutSeconds, 40)
    }

    func testInvalidJSONReturnsDefaultsAndError() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        let loaded = Tuning.load(from: url)
        XCTAssertEqual(loaded.tuning, Tuning())
        XCTAssertNotNil(loaded.error)
    }

    func testMissingFileIsNotAnError() {
        let loaded = Tuning.load(from: tempURL())
        XCTAssertEqual(loaded.tuning, Tuning())
        XCTAssertNil(loaded.error)
    }
}
