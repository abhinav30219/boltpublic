import Foundation

/// Turns important insight events into short memory facts, written from the computed facts
/// (never from the model's wording). Routine events (band contact, activity switches) are skipped.
public enum InsightMemory {
    private static let when: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE MMM d, h:mm a"; return f }()

    public static func fact(for e: InsightEvent) -> String? {
        func f(_ label: String) -> String? { e.facts.first { $0.label == label }?.text }
        let t = when.string(from: e.createdAt)
        switch e.kind {
        case .recovery:
            guard let peak = f("Peak heart rate") else { return nil }
            var s = "\(t): heart rate peaked at \(peak) during activity"
            if let rec = f("Seconds from peak to near resting") { s += " and was back near resting \(rec) later" }
            return s + "."
        case .elevatedAtRest:
            guard let now = f("Heart rate now"), let base = f("Resting heart rate") else { return nil }
            return "\(t): heart rate was \(now) while sitting still, above the usual resting \(base)."
        case .skinTempShift:
            guard let a = f("Skin temperature before"), let b = f("Skin temperature now") else { return nil }
            return "\(t): wrist temperature changed from \(a) to \(b)" + (f("Minutes").map { " over \($0)" } ?? "") + "."
        case .workoutFinished:
            guard let kind = f("Workout type"), let mins = f("Workout minutes") else { return nil }
            var s = "\(t): \(mins) of \(kind)"
            if let avg = f("Average heart rate") { s += ", average heart rate \(avg)" }
            if let peak = f("Peak heart rate") { s += ", peak \(peak)" }
            if let steps = f("Steps") { s += ", \(steps) steps" }
            return s + "."
        case .safety:
            return "\(t): safety alert. " + e.facts.map { "\($0.label) \($0.text)" }.joined(separator: ", ") + "."
        case .fall:
            let answer = f("Response").map { " The user answered: \($0)." } ?? ""
            return "\(t): possible fall detected" + (f("Impact").map { " (impact \($0))" } ?? "") + "." + answer
        case .moment:
            return "\(t): the user marked a moment" + (f("Heart rate now").map { " (heart rate \($0)" + (f("Activity").map { ", \($0)" } ?? "") + ")" } ?? "") + "."
        case .exertion, .activityChange, .bandOff, .wave:
            return nil
        }
    }
}

/// One finished question and answer from a chat.
public struct ChatTurn: Sendable, Equatable {
    public var question: String
    public var answer: String
    public init(question: String, answer: String) { self.question = question; self.answer = answer }
}

/// Builds what Gemma knows beyond the current question: things the user told it, a running summary
/// of the older part of this chat, the last few turns word for word, and a line about recent other
/// chats. Kept short on purpose; every character is prefill on every question.
public enum ConversationContext {
    public static let recentTurns = 3

    public static func block(memories: [MemoryFact], summary: String, recent: [ChatTurn],
                             otherChats: [(title: String, gist: String)], falls: [String]? = nil) -> String {
        var parts: [String] = []
        // Safety facts first and stated plainly: the 2B model otherwise trusted a stale chat summary
        // ("no falls") over the saved fall events.
        if let falls {
            parts.append(falls.isEmpty ? "Falls detected by the band in the last 48 hours: none recorded."
                         : "Falls detected by the band in the last 48 hours (" + String(falls.count) + "):\n" + falls.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !memories.isEmpty {
            parts.append("True facts about the user and events the band recorded (newest and most relevant first):\n" + memories.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if !otherChats.isEmpty {
            parts.append("Other recent chats (may be outdated or wrong; the facts above and tool results win):\n" + otherChats.map { "- \($0.title): \($0.gist)" }.joined(separator: "\n"))
        }
        if !summary.isEmpty { parts.append("Summary of this chat so far:\n\(summary)") }
        if !recent.isEmpty {
            parts.append("Latest turns in this chat (live numbers may have changed; call tools again for current values):\n"
                + recent.map { "User: \(clip($0.question, 300))\nGemma: \(clip($0.answer, 200))" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Band-detected falls from the last 48 hours, newest first, as saved in memory. Simulated falls
    /// (saved so the memory path can be tested) are tagged "(simulated" and left out.
    public static func recentFalls(store: MemoryStore, now: Date = Date()) -> [String] {
        store.facts.filter { $0.source == "insight" && $0.text.contains("possible fall detected") && !$0.text.contains("(simulated") && now.timeIntervalSince($0.createdAt) < 48 * 3600 }
            .sorted { $0.createdAt > $1.createdAt }.prefix(6).map { $0.text }
    }

    /// Facts for the prompt: the ones that match the question first, then the newest, without repeats.
    public static func memories(for question: String, store: MemoryStore, limit: Int = 8) -> [MemoryFact] {
        var out: [MemoryFact] = []
        for f in store.recall(question, limit: 4) + store.facts.sorted(by: { $0.createdAt > $1.createdAt }) where !out.contains(where: { $0.id == f.id }) {
            out.append(f)
            if out.count == limit { break }
        }
        return out
    }

    /// Prompt asking Gemma to fold turns that left the recent window into the running summary.
    public static func summaryPrompt(previous: String, turns: [ChatTurn]) -> (system: String, user: String) {
        let system = "You keep a running summary of a health chat between a user and Gemma. At most 70 words, plain sentences, no lists, no markdown. Keep what the user said about themselves, numbers Gemma reported and anything left open. Write only the summary."
        var user = previous.isEmpty ? "Summary so far: (none)\n" : "Summary so far: \(previous)\n"
        user += "New turns:\n" + turns.map { "User: \(clip($0.question, 300))\nGemma: \(clip($0.answer, 400))" }.joined(separator: "\n")
        user += "\nWrite the updated summary."
        return (system, user)
    }

    /// Used when Gemma can't write the summary: the questions, newest last, capped.
    public static func fallbackSummary(previous: String, turns: [ChatTurn]) -> String {
        let added = turns.map { "The user asked: \(clip($0.question, 120))" }.joined(separator: " ")
        let all = previous.isEmpty ? added : previous + " " + added
        return all.count <= 600 ? all : String(all.suffix(600))
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }
}
