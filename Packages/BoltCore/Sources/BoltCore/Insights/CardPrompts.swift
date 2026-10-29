import Foundation

public enum CardPrompts {
    /// Kept short on purpose: every token here is prefill on every card.
    public static let system = """
    You are Bolt, a small robot companion who talks out loud to the user, like a friend sitting next to them. Your line is spoken aloud, so it must sound natural said aloud.
    The facts are about the user's body, not yours: say "your heart rate", never "my heart rate".
    Rules: One short sentence, under 20 words, casual and friendly. At most one number, written as digits exactly as given (72 bpm, never seventy-two). Use only the facts given; never add numbers. Say what their body is doing; never guess how they feel; never diagnose. No emojis, no lists, no markdown.
    """

    public static func userMessage(for event: InsightEvent, name: String?, memory: [String]) -> String {
        var lines = ["Event: \(event.kind.title)"]
        if let hint = hint(for: event.kind) { lines.append("Context: \(hint)") }
        for f in event.facts { lines.append("- \(f.label): \(f.text)") }
        if !memory.isEmpty {
            lines.append("Things the user told Bolt earlier (use only if relevant):")
            for m in memory.prefix(3) { lines.append("- \(m)") }
        }
        if let name, !name.isEmpty { lines.append("User's first name: \(name). Use it now and then, not every time.") }
        lines.append("Say your one line.")
        return lines.joined(separator: "\n")
    }

    /// One line of framing per event so the model doesn't misread the situation.
    static func hint(for kind: TriggerKind) -> String? {
        switch kind {
        case .exertion: return "The user is moving, so a higher heart rate is expected. Don't tell them to calm down or slow their breathing."
        case .recovery: return "Their effort has ended. Say how far it came down from the peak and how quickly."
        case .elevatedAtRest: return "The user is still, yet their heart rate is above their usual resting level."
        case .activityChange: return "Name what they're doing now."
        case .workoutFinished: return "A workout just ended. Say how long it lasted and the most notable number, such as steps or heart rate."
        case .skinTempShift: return "Mention that room temperature and movement affect wrist temperature."
        case .wave: return "The user just waved at you and you waved back. Say hi, then tell them the one most interesting thing about their day from the facts. If a fall earlier is listed, gently ask how they feel after it."
        default: return nil
        }
    }

    /// Used when the model is unavailable, too slow, or its card fails the number check.
    public static func template(for event: InsightEvent) -> String {
        if let fixed = event.fixedText { return fixed }
        func f(_ label: String) -> String { event.facts.first { $0.label == label }?.text ?? "" }
        switch event.kind {
        case .exertion:
            return "Ooh, you're getting moving, heart's up to \(f("Heart rate now"))!"
        case .recovery:
            return "Nice, your heart settled back down to \(f("Heart rate now")) already."
        case .elevatedAtRest:
            return "Your heart's at \(f("Heart rate now")) while you're resting, want to take a few slow breaths with me?"
        case .activityChange:
            let hr = f("Heart rate now")
            _ = hr
            return "Looks like you're \(f("New activity")) now, love it!"
        case .skinTempShift:
            return "Your wrist's cooled to \(f("Skin temperature now")), maybe grab a sweater?"
        case .workoutFinished:
            return "Great \(f("Workout type")), \(f("Workout minutes")) of moving, well done!"
        case .fall:
            return "It looks like you may have fallen. If you're hurt, get help."
        case .wave:
            if !f("Fall earlier").isEmpty { return "Hi there! How are you feeling after your fall earlier?" }
            if !f("Steps today").isEmpty { return "Hi there! You've done \(f("Steps today")) steps so far today." }
            if !f("Heart rate now").isEmpty { return "Hi there! Your heart rate is \(f("Heart rate now")) right now." }
            return "Hi there! Good to see you."
        case .moment:
            return "Got it, I'll remember this moment."
        case .bandOff:
            return ""   // band-off is never shown to the user
        case .safety:
            return "Please stop and rest."
        }
    }
}

/// Rejects a model-written card if it states a number that isn't in the facts.
public enum NumberGuard {
    public static func numbers(in text: String) -> [Double] {
        var out: [Double] = []
        var cur = ""
        func flush() {
            let t = cur.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !t.isEmpty, let v = Double(t) { out.append(v) }
            cur = ""
        }
        for ch in text {
            if ch.isNumber || (ch == "." && !cur.isEmpty) { cur.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    /// Small counting words (1, 2, 3...) and percentages tied to facts are allowed; any other number
    /// must match a fact value within rounding.
    /// Spelled-out numbers would slip past the digit check, so they fail outright.
    static let numberWords = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
                              "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]

    public static func isFaithful(_ card: String, facts: [InsightFact], allowed: Set<Double> = [1, 2, 3, 4, 5]) -> Bool {
        let lower = card.lowercased()
        if numberWords.contains(where: { lower.contains($0) }) { return false }
        if leaksMarkup(card) || looksGarbled(card) { return false }
        let factNums = facts.compactMap { $0.number } + facts.flatMap { numbers(in: $0.text) }
        for n in numbers(in: card) {
            if allowed.contains(n) { continue }
            if factNums.contains(where: { abs($0 - n) <= max(0.51, abs($0) * 0.01) }) { continue }
            // Allow simple differences between two facts (e.g. "rose 44 bpm").
            var isDiff = false
            for a in factNums { for b in factNums where abs(abs(a - b) - n) <= 0.51 { isDiff = true } }
            if isDiff { continue }
            return false
        }
        return true
    }

    /// True if model text still carries tool-call or control-token syntax after cleaning.
    public static func leaksMarkup(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["<|", "|>", "call:", "tool_call", "tool_response", "{", "}", "```", "<start_of_turn", "<end_of_turn"].contains { l.contains($0) }
    }

    /// Catches the broken output we saw on the phone: other scripts mixed in, run-on tokens,
    /// the same word repeated, or mostly symbols.
    public static func looksGarbled(_ s: String, strict: Bool = true) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 8 else { return true }
        let latin = letters.filter { $0.value < 0x250 }   // Basic Latin through Latin Extended
        if Double(latin.count) / Double(letters.count) < 0.95 { return true }
        let ok = t.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) || ".,;:!?'’\"%°-()/".unicodeScalars.contains($0) }
        if strict, Double(ok.count) / Double(t.unicodeScalars.count) < 0.95 { return true }
        let words = t.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" })
        if words.contains(where: { $0.count > 24 }) { return true }
        var run = 1
        for i in words.indices.dropFirst() {
            run = words[i] == words[words.index(before: i)] ? run + 1 : 1
            if run >= 3 { return true }
        }
        return false
    }

    /// Strips stray formatting the model sometimes emits, including Gemma's tool-call and
    /// control tokens (`<|tool_call>call:name{...}<tool_call|>`, `<|"|>`, turn markers).
    public static func clean(_ s: String) -> String {
        var t = s
        for pattern in [#"<\|tool_call>call:[a-z_]+\{[^}]*\}(<tool_call\|>)?"#, #"<\|tool_call>[\s\S]*?(<tool_call\|>|$)"#, #"<\|tool_response>[\s\S]*?(<tool_response\|>|$)"#,
                        #"call:[a-z_]+\{[^}]*\}?"#, #"<\|[^>]*>"#, #"<[a-z_]+\|>"#, #"</?(start|end)_of_turn>"#, #"<\|[^>]*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 1 { t = String(t.dropFirst().dropLast()) }
        return t
    }
}
