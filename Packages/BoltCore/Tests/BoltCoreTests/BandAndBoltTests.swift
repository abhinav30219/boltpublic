import XCTest
@testable import BoltCore

/// Wear state, the temperature fallback, drink recall and the wave line.
final class BandAndBoltTests: XCTestCase {
    func testWearStateMapsToWorn() {
        XCTAssertEqual(WearStatusSample(tMs: 0, state: .on).isWorn, true)
        XCTAssertEqual(WearStatusSample(tMs: 0, state: .off).isWorn, false)
        XCTAssertNil(WearStatusSample(tMs: 0, state: .unknown).isWorn)
    }

    func testWearOnMakesStoreWorn() {
        let store = MetricsStore()
        store.ingest(.wear(WearStatusSample(tMs: 0, state: .on)))
        XCTAssertEqual(store.wornFromWear, true)
        XCTAssertTrue(store.isWorn)
    }

    func testTemperatureFallsBackToSensorBOnlyWhenAIsQuiet() {
        let store = MetricsStore()
        let t0 = Date()
        store.ingest(.temperature(TemperatureSample(tMs: 0, celsius: 31.0, sensor: .a)), at: t0)
        store.ingest(.temperature(TemperatureSample(tMs: 0, celsius: 29.0, sensor: .b)), at: t0.addingTimeInterval(10))
        XCTAssertEqual(store.latest(.skinTemp, maxAge: 600, now: t0.addingTimeInterval(10)), 31.0, "B ignored while A is live")
        store.ingest(.temperature(TemperatureSample(tMs: 0, celsius: 29.5, sensor: .b)), at: t0.addingTimeInterval(90))
        XCTAssertEqual(store.latest(.skinTemp, maxAge: 600, now: t0.addingTimeInterval(90)), 29.5, "B used after A is quiet for a minute")
    }

    func testDrinkRecallFindsCoffee() {
        let m = MemoryStore(url: nil)
        m.add("I had two coffees this morning", source: "chat")
        m.add("I went for a short walk after lunch", source: "chat")
        XCTAssertEqual(m.recall("drinks").first?.text, "I had two coffees this morning")
        XCTAssertEqual(m.recall("What did I drink today?").first?.text, "I had two coffees this morning")
        XCTAssertEqual(m.recall("did I exercise").first?.text, "I went for a short walk after lunch")
    }

    func testWaveTemplatePrefersFallThenSteps() {
        let fall = InsightEvent(kind: .wave, createdAt: Date(), facts: [InsightFact(label: "Fall earlier", text: "at 4:28 PM, they said they were okay"),
                                                                        .num("Steps today", 85, "")])
        XCTAssertEqual(CardPrompts.template(for: fall), "Hi there! How are you feeling after your fall earlier?")
        let steps = InsightEvent(kind: .wave, createdAt: Date(), facts: [.num("Steps today", 85, "")])
        XCTAssertEqual(CardPrompts.template(for: steps), "Hi there! You've done 85 steps so far today.")
        XCTAssertNotNil(RobotCommand.say(CardPrompts.template(for: steps)))
    }

    func testCardPromptSpeaksAboutTheUsersBody() {
        XCTAssertTrue(CardPrompts.system.contains("never \"my heart rate\""))
    }
}
