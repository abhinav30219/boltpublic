import XCTest
@testable import BoltCore

final class CoreLogicTests: XCTestCase {

    /// Plays the synthetic session through the store, the activity fallback and the trigger engine,
    /// the way the app's 1 Hz loop does.
    private func runSynthetic(until end: Double = SyntheticSession.total) -> (MetricsStore, [InsightEvent]) {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MetricsStore()
        let engine = TriggerEngine()
        var smoother = ActivitySmoother()
        var events: [InsightEvent] = []
        let items = SyntheticSession.make()
        var idx = 0
        var tick = 0.0
        while tick <= end {
            while idx < items.count && items[idx].t <= tick {
                store.ingest(items[idx].input, at: t0.addingTimeInterval(items[idx].t))
                idx += 1
            }
            let now = t0.addingTimeInterval(tick)
            var changed: ActivityClass?
            var previous: ActivityClass?
            if Int(tick) % 5 == 0, let w = store.accelWindow(now: now) {
                let (cls, p) = ActivityMath.heuristic(window: w)
                previous = smoother.current
                changed = smoother.update(cls, probability: p)
                store.ingest(activity: ActivityPoint(t: now, activity: smoother.current ?? cls, probability: p))
            }
            events += engine.evaluate(store, now: now, activityChangedTo: changed, previousActivity: previous)
            tick += 1
        }
        return (store, events)
    }

    func testBaselineEstablishesAfterCalibration() {
        let (store, _) = runSynthetic(until: 140)
        XCTAssertTrue(store.baseline.isEstablished)
        XCTAssertEqual(store.baseline.heartRate!, 67, accuracy: 3)
        XCTAssertNotNil(store.baseline.hrv)
        XCTAssertNotNil(store.baseline.skinTemp)
    }

    func testSyntheticSessionFiresExertionThenRecovery() {
        let (_, events) = runSynthetic()
        let kinds = events.map { $0.kind }
        guard let ex = kinds.firstIndex(of: .exertion), let rec = kinds.firstIndex(of: .recovery) else {
            return XCTFail("expected exertion and recovery, got \(kinds)")
        }
        XCTAssertLessThan(ex, rec)
        let exEvent = events[ex]
        XCTAssertGreaterThan(exEvent.createdAt.timeIntervalSince1970 - 1_800_000_000, SyntheticSession.restEnd)
        XCTAssertLessThan(exEvent.createdAt.timeIntervalSince1970 - 1_800_000_000, SyntheticSession.effortEnd)
        XCTAssertNotEqual(exEvent.facts.first { $0.label == "Activity" }?.text, "still", "exertion cards must not say still")
        XCTAssertTrue(events[rec].facts.contains { $0.label == "Peak heart rate" && ($0.number ?? 0) > 105 })
        XCTAssertFalse(kinds.contains(.bandOff))
        XCTAssertFalse(kinds.contains(.safety))
        XCTAssertFalse(kinds.contains(.elevatedAtRest), "rest HR is normal in the synthetic session")
    }

    func testSyntheticSessionFiresActivityChangeAndTemperature() {
        let (_, events) = runSynthetic()
        XCTAssertTrue(events.contains { $0.kind == .activityChange })
        XCTAssertTrue(events.contains { $0.kind == .skinTempShift }, "\(events.map { $0.kind })")
    }

    func testCooldownPreventsRepeatCards() {
        let (_, events) = runSynthetic()
        let ex = events.filter { $0.kind == .exertion }
        XCTAssertEqual(ex.count, 1)
    }

    func testBandOffFiresOnceWhenSignalLost() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MetricsStore(), engine = TriggerEngine()
        for s in 0..<20 { store.ingest(.cardiac(CardiacReading(seq: UInt16(s + 1), hrBpm: 70, validPermille: 900)), at: t0.addingTimeInterval(Double(s))) }
        var events: [InsightEvent] = []
        for s in 20..<70 {
            let now = t0.addingTimeInterval(Double(s))
            store.ingest(.cardiac(CardiacReading(seq: UInt16(s + 1), hrBpm: nil, validPermille: 0)), at: now)
            events += engine.evaluate(store, now: now)
        }
        XCTAssertEqual(events.filter { $0.kind == .bandOff }.count, 1)
    }

    func testElevatedAtRestFires() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MetricsStore(), engine = TriggerEngine()
        store.calibrationSeconds = 60
        var events: [InsightEvent] = []
        for s in 0..<300 {
            let now = t0.addingTimeInterval(Double(s))
            let hr: Double = s < 120 ? 64 : 92
            let rmssd: Double = s < 120 ? 60 : 30
            store.ingest(.cardiac(CardiacReading(seq: UInt16(s + 1), hrBpm: hr, rmssdMs: rmssd, validPermille: 900)), at: now)
            let still = (0..<3).map { i in IMUSample(tMs: Double(s) * 1000 + Double(i) * 33, axMS2: 0.1, ayMS2: 0.2, azMS2: 9.8) }
            store.ingest(.imu(still), at: now)
            if s % 5 == 0 { store.ingest(activity: ActivityPoint(t: now, activity: .stationary, probability: 0.9)) }
            events += engine.evaluate(store, now: now)
        }
        XCTAssertTrue(events.contains { $0.kind == .elevatedAtRest }, "\(events.map { $0.kind })")
        XCTAssertFalse(events.contains { $0.kind == .exertion })
    }

    func testSafetyMessageIsCodeWritten() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MetricsStore(), engine = TriggerEngine()
        store.calibrationSeconds = 30
        var events: [InsightEvent] = []
        for s in 0..<200 {
            let now = t0.addingTimeInterval(Double(s))
            store.ingest(.cardiac(CardiacReading(seq: UInt16(s + 1), hrBpm: s < 60 ? 70 : 160, validPermille: 900)), at: now)
            store.ingest(.imu([IMUSample(tMs: Double(s) * 1000, axMS2: 0, ayMS2: 0, azMS2: 9.8), IMUSample(tMs: Double(s) * 1000 + 33, axMS2: 0.01, ayMS2: 0, azMS2: 9.81)]), at: now)
            if s % 5 == 0 { store.ingest(activity: ActivityPoint(t: now, activity: .stationary, probability: 0.9)) }
            events += engine.evaluate(store, now: now)
        }
        let safety = events.filter { $0.kind == .safety }
        XCTAssertEqual(safety.count, 1)
        XCTAssertNotNil(safety.first?.fixedText)
        XCTAssertEqual(CardPrompts.template(for: safety[0]), safety[0].fixedText)
    }

    func testAccelWindowShapeAndScale() {
        let (store, _) = runSynthetic(until: 60)
        let w = store.accelWindow(now: Date(timeIntervalSince1970: 1_800_000_060))
        XCTAssertEqual(w?.count, 3)
        XCTAssertEqual(w?[0].count, 900)
        XCTAssertEqual(Double(w![2][450]), 0.99, accuracy: 0.05)   // gravity on z, in g
    }

    func testActivityMathFoldsStairsIntoWalk() {
        let (cls, p) = ActivityMath.classify(logits: [0, 0, 2, 0, 0, 2])!
        XCTAssertEqual(cls, .walk)
        XCTAssertGreaterThan(p, 0.7)
        XCTAssertNil(ActivityMath.classify(logits: [1, 2]))
    }

    func testSmootherNeedsTwoConfidentWindows() {
        var s = ActivitySmoother()
        XCTAssertNil(s.update(.stationary, probability: 0.9))
        XCTAssertNil(s.update(.walk, probability: 0.9))
        XCTAssertNil(s.update(.walk, probability: 0.5))
        XCTAssertEqual(s.update(.walk, probability: 0.8), .walk)
        XCTAssertNil(s.update(.stairs, probability: 0.9), "stairs counts as walking")
    }

    func testNumberGuard() {
        let facts: [InsightFact] = [.num("Resting heart rate", 67.4, "bpm"), .num("Heart rate now", 118, "bpm"), .num("Seconds to rise", 38, "s")]
        XCTAssertTrue(NumberGuard.isFaithful("Heart rate went from 67 to 118 in 38 seconds.", facts: facts))
        XCTAssertTrue(NumberGuard.isFaithful("Up 51 bpm from your resting rate.", facts: facts), "difference of two facts")
        XCTAssertFalse(NumberGuard.isFaithful("Heart rate hit 140, about 85% of max.", facts: facts))
        XCTAssertTrue(NumberGuard.isFaithful("Take 3 slow breaths.", facts: facts))
        XCTAssertFalse(NumberGuard.isFaithful("Your heart rate is one hundred eighteen beats per minute.", facts: facts), "spelled-out numbers dodge the digit check")
        XCTAssertEqual(NumberGuard.numbers(in: "33.4 °C, then 32.6."), [33.4, 32.6])
        XCTAssertEqual(NumberGuard.clean("\"**Nice** work.\""), "Nice work.")
    }

    func testTemplatesUseFacts() {
        let e = InsightEvent(kind: .exertion, createdAt: Date(), facts: [.num("Resting heart rate", 67, "bpm"), .num("Heart rate now", 118, "bpm"), .num("Seconds to rise", 38, "s")])
        let t = CardPrompts.template(for: e)
        XCTAssertTrue(t.contains("118 bpm"), t)
        XCTAssertLessThan(t.split(separator: " ").count, 20, "spoken templates stay one short line")
        XCTAssertTrue(NumberGuard.isFaithful(t, facts: e.facts))
        let prompt = CardPrompts.userMessage(for: e, name: "Maya", memory: ["Slept 5 hours last night"])
        XCTAssertTrue(prompt.contains("Heart rate now: 118 bpm") && prompt.contains("Slept 5 hours"))
    }

    func testMemoryExtractionAndRecall() throws {
        let facts = MemoryStore.extractFacts(from: "I slept 5 hours last night and I had coffee at 9. Should I run?")
        XCTAssertEqual(facts, ["I slept 5 hours last night", "I had coffee at 9"])
        XCTAssertEqual(MemoryStore.extractFacts(from: "remember that I'm training for a half marathon"), ["I'm training for a half marathon"])
        XCTAssertEqual(MemoryStore.extractFacts(from: "How is my heart?"), [])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString).json")
        let m = MemoryStore(url: url)
        m.add("I slept 5 hours last night", source: "chat")
        m.add("I had coffee at 9", source: "chat")
        m.add("I had coffee at 9", source: "chat")
        XCTAssertEqual(m.facts.count, 2)
        XCTAssertEqual(m.recall("Should I have caffeine?").first?.text, "I had coffee at 9")
        XCTAssertEqual(m.recall("how tired am I, poor sleep?").first?.text, "I slept 5 hours last night")
        XCTAssertEqual(MemoryStore(url: url).facts.count, 2, "persists")
    }

    func testCorruptMemoryFileIsMovedAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("memory.json")
        try Data("{ not valid json".utf8).write(to: url)
        let m = MemoryStore(url: url)
        XCTAssertTrue(m.facts.isEmpty)
        m.add("I had coffee at 9", source: "chat")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("memory.corrupt-") && $0.hasSuffix(".json") })
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(aside)), "{ not valid json")
        XCTAssertEqual(MemoryStore(url: url).facts.count, 1)
    }

    func testToolsReturnValidJSON() {
        let (store, events) = runSynthetic()
        let memory = MemoryStore(url: nil)
        memory.add("I slept 5 hours last night", source: "chat")
        let cards = events.map { InsightCard(event: $0, text: CardPrompts.template(for: $0), source: .template, isStreaming: false) }
        let tools = HealthTools(store: store, memory: memory, cards: cards, now: Date(timeIntervalSince1970: 1_800_000_000 + SyntheticSession.total))
        for obj in [tools.liveMetrics(windowSeconds: 60), tools.trend(metric: "heart rate", minutes: 10), tools.trend(metric: "bogus", minutes: 5),
                    tools.activityTimeline(minutes: 10), tools.recentInsights(count: 3), tools.recallMemory(query: "sleep")] {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(obj), "\(obj)")
        }
        let trend = tools.trend(metric: "hr", minutes: 5)
        XCTAssertEqual(trend["metric"] as? String, "heart_rate")
        XCTAssertEqual((trend["points"] as? [Any])?.count, 12)
        XCTAssertNotNil(tools.trend(metric: "bogus", minutes: 5)["error"])
        XCTAssertTrue(HealthTools.json(tools.recallMemory(query: "sleep")).contains("5 hours"))
    }

    func testRecorderRoundTripThroughDecoder() throws {
        let rec = SessionRecorder()
        rec.record(.cardiac(CardiacReading(hrBpm: 72, rmssdMs: 40, spo2Pct: 98, validPermille: 900)),
                   at: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).jsonl")
        try rec.write(to: url)
        let loaded = try SessionRecorder.load(from: url)
        XCTAssertEqual(loaded, rec.items)
        let inputs = NotificationDecoder().decode(loaded[0])
        guard case .cardiac(let r)? = inputs.first else { return XCTFail("no cardiac") }
        XCTAssertEqual(r.hrBpm, 72)
    }
}
