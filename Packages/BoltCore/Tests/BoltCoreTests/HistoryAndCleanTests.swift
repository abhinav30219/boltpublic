import XCTest
@testable import BoltCore

final class HistoryAndCleanTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testCleanStripsToolCallMarkup() {
        let raw = "<|tool_call>call:get_live_metrics{window_seconds:60}<tool_call|>Your heart rate is 72 bpm.<|\"|>"
        XCTAssertEqual(NumberGuard.clean(raw), "Your heart rate is 72 bpm.")
        XCTAssertEqual(NumberGuard.clean("Resting at 64 bpm. <|tool_ca"), "Resting at 64 bpm.")
    }

    func testGarbledCardsFallBackToTemplate() {
        let facts: [InsightFact] = [.num("Heart rate now", 118, "bpm")]
        XCTAssertTrue(NumberGuard.isFaithful("Your heart rate is 118 bpm as you move.", facts: facts))
        XCTAssertFalse(NumberGuard.isFaithful("call:get_trend{metric:heart_rate} 118", facts: facts))
        XCTAssertFalse(NumberGuard.isFaithful("Your heart heart heart rate 118", facts: facts))
        XCTAssertFalse(NumberGuard.isFaithful("心率 118 bpm отличный ритм", facts: facts))
        XCTAssertFalse(NumberGuard.isFaithful("Heartrateisrisingveryquicklyrightnowwow 118", facts: facts))
    }

    func testMemoryFromInsideQuestions() {
        XCTAssertEqual(MemoryStore.extractFacts(from: "Why is my heart rate fluctuating today? Is it because I drank coffee earlier?"), ["I drank coffee earlier"])
        XCTAssertEqual(MemoryStore.extractFacts(from: "But now you know I drank coffee, right?"), ["I drank coffee"])
    }

    func testInsightMemoriesComeFromFacts() {
        let rec = InsightEvent(kind: .recovery, createdAt: Date(), facts: [.num("Peak heart rate", 122, "bpm"), .num("Heart rate now", 70, "bpm"), .num("Seconds from peak to near resting", 75, "s")])
        let f = InsightMemory.fact(for: rec)
        XCTAssertTrue(f?.contains("peaked at 122 bpm") == true && f?.contains("75 s later") == true, f ?? "nil")
        XCTAssertNil(InsightMemory.fact(for: InsightEvent(kind: .bandOff, createdAt: Date(), facts: [])), "routine events are not remembered")
        XCTAssertNil(InsightMemory.fact(for: InsightEvent(kind: .activityChange, createdAt: Date(), facts: [])))
    }

    func testSaveMemoryToolDedupes() {
        let mem = MemoryStore(url: nil)
        let tools = HealthTools(store: MetricsStore(), memory: mem, cards: [])
        XCTAssertEqual(tools.saveMemory(fact: "I drank two coffees this morning")["saved"] as? Bool, true)
        XCTAssertEqual(tools.saveMemory(fact: "i drank two coffees this morning")["saved"] as? Bool, false)
        XCTAssertEqual(tools.saveMemory(fact: "hi")["saved"] as? Bool, false)
        XCTAssertEqual(mem.facts.count, 1)
    }

    func testConversationContextCarriesMemoryAndTurns() {
        let mem = MemoryStore(url: nil)
        mem.add("I drank coffee earlier", source: "chat")
        mem.add("I slept 5 hours last night", source: "chat")
        let picked = ConversationContext.memories(for: "why is my heart rate high, is it the caffeine?", store: mem)
        XCTAssertEqual(picked.first?.text, "I drank coffee earlier", "relevant facts first")
        let block = ConversationContext.block(memories: picked, summary: "User asked about resting heart rate.",
                                              recent: [ChatTurn(question: "How is my heart?", answer: "77 bpm right now.")],
                                              otherChats: [(title: "Sleep", gist: "talked about a short night")])
        for needle in ["I drank coffee earlier", "Summary of this chat so far", "User: How is my heart?", "Gemma: 77 bpm", "Sleep: talked about"] {
            XCTAssertTrue(block.contains(needle), needle)
        }
        let fb = ConversationContext.fallbackSummary(previous: "", turns: [ChatTurn(question: "Q1", answer: "A1")])
        XCTAssertEqual(fb, "The user asked: Q1")
    }

    func testMoreMemoryCues() {
        XCTAssertEqual(MemoryStore.extractFacts(from: "I just had a big lunch, should I wait to run?"), ["I just had a big lunch"])
        XCTAssertEqual(MemoryStore.extractFacts(from: "I took ibuprofen an hour ago"), ["I took ibuprofen an hour ago"])
    }

    func testFallsAreFoundInMemoryAndRecentEvents() {
        let mem = MemoryStore(url: nil)
        mem.add("Sat Oct 24, 3:58 PM: possible fall detected (impact 4.7 g). The user answered: they are OK.", source: "insight")
        mem.add("I drank coffee earlier", source: "chat")
        XCTAssertEqual(ConversationContext.memories(for: "Did I fall today?", store: mem).first?.text.contains("fall"), true)
        XCTAssertEqual(MemoryStore.extractFacts(from: "I fell down a few times today"), ["I fell down a few times today"])
        let tools = HealthTools(store: MetricsStore(), memory: mem, cards: [])
        let events = tools.recentInsights(count: 5)["insights"] as? [[String: Any]]
        XCTAssertTrue((events?.first?["event"] as? String)?.contains("possible fall") == true, "saved insight memories show up after a restart")
    }

    func testInlineToolCallWithoutClosingTagKeepsTheAnswer() {
        let raw = "<|tool_call>call:save_memory{fact:<|\"|>I fell down earlier in the kitchen.<|\"|>} I see that you mentioned falling in the kitchen."
        XCTAssertEqual(NumberGuard.clean(raw), "I see that you mentioned falling in the kitchen.")
        let mem = MemoryStore(url: nil)
        mem.add("Sat Oct 24, 4:28 PM: possible fall detected (impact 4.9 g). The user answered: they are OK.", source: "insight")
        let block = ConversationContext.block(memories: [], summary: "", recent: [], otherChats: [(title: "Fall?", gist: "Gemma reported no falls")],
                                              falls: ConversationContext.recentFalls(store: mem))
        XCTAssertTrue(block.hasPrefix("Falls detected by the band in the last 48 hours (1):"), block)
    }
}

final class SimulatedFallMemoryTests: XCTestCase {
    func testSimulatedFallsAreNotListedAsRecentFalls() {
        let m = MemoryStore(url: nil)
        _ = m.add("Sat Oct 24, 4:28 PM: possible fall detected (impact 4.2 g). The user answered: they are OK.", source: "insight")
        _ = m.add("Sat Oct 24, 4:30 PM: possible fall detected. The user answered: no response. (simulated, not a real fall)", source: "insight")
        XCTAssertEqual(ConversationContext.recentFalls(store: m).count, 1)
    }
}
