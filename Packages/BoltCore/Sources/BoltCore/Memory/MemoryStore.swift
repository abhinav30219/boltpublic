import Foundation

public struct UserProfile: Codable, Sendable, Equatable {
    public var name: String = ""
    public var age: Int?
    public var goals: [String] = []
    public var notes: String = ""
    public init() {}

    public var summary: String {
        var parts: [String] = []
        if !name.isEmpty { parts.append("Name: \(name)") }
        if let age { parts.append("Age: \(age)") }
        if !goals.isEmpty { parts.append("Goals: \(goals.joined(separator: ", "))") }
        if !notes.isEmpty { parts.append("Notes: \(notes)") }
        return parts.joined(separator: ". ")
    }

    public static let goalOptions = ["Train smarter", "Sleep better", "Manage stress", "Understand my cycle", "Stay on top of my health"]
}

public struct MemoryFact: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var text: String
    public var createdAt: Date
    public var source: String   // "chat", "manual", "onboarding"
    public init(text: String, createdAt: Date = Date(), source: String) {
        self.text = text; self.createdAt = createdAt; self.source = source
    }
}

/// Small on-device memory: facts the user tells Bolt. JSON file in Application Support.
public final class MemoryStore {
    public private(set) var facts: [MemoryFact] = []
    private let url: URL?

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder.iso.decode([MemoryFact].self, from: data) {
                facts = decoded
            } else {
                Self.moveAside(url)   // keep the unreadable file instead of overwriting it on the next add()
            }
        }
    }

    private static func moveAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(url.deletingPathExtension().lastPathComponent).corrupt-\(stamp).\(url.pathExtension.isEmpty ? "json" : url.pathExtension)"
        try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name))
    }

    @discardableResult
    public func add(_ text: String, source: String, at date: Date = Date()) -> MemoryFact? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if facts.contains(where: { $0.text.lowercased() == t.lowercased() }) { return nil }
        let f = MemoryFact(text: t, createdAt: date, source: source)
        facts.append(f)
        save()
        return f
    }

    public func remove(_ id: UUID) { facts.removeAll { $0.id == id }; save() }

    /// Keeps only the newest `keep` facts from one source (insight memories would otherwise pile up).
    public func prune(source: String, keep: Int) {
        let mine = facts.filter { $0.source == source }.sorted { $0.createdAt > $1.createdAt }
        guard mine.count > keep else { return }
        let drop = Set(mine.dropFirst(keep).map { $0.id })
        facts.removeAll { drop.contains($0.id) }
        save()
    }
    public func removeAll() { facts = []; save() }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(facts) { try? data.write(to: url, options: .atomic) }
    }

    private static let stop: Set<String> = ["the", "a", "an", "i", "my", "me", "is", "was", "and", "or", "to", "of", "in", "on", "at", "for", "do", "did", "should", "can", "have", "had", "what", "how", "today", "now", "it", "this", "that", "be", "with"]

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Keyword recall, newest first among equal scores. Returns all recent facts if the query is empty.
    public func recall(_ query: String, limit: Int = 5) -> [MemoryFact] {
        let q = Self.words(query)
        let drinks = ["drink", "drank", "coffee", "coffees", "tea", "wine", "beer", "alcohol", "water", "juice", "soda", "espresso", "latte"]
        let foods = ["ate", "food", "breakfast", "lunch", "dinner", "snack", "meal"]
        let synonyms: [String: [String]] = [
            "coffee": ["caffeine", "espresso", "latte", "tea"], "caffeine": ["coffee", "espresso", "tea"],
            "sleep": ["slept", "night", "bed", "tired"], "slept": ["sleep"], "run": ["running", "workout", "exercise", "training"],
            "workout": ["exercise", "gym", "run", "training"], "stress": ["stressed", "anxious", "work"],
            "alcohol": ["drink", "wine", "beer"], "period": ["cycle", "menstrual"], "cycle": ["period"],
            "fall": ["fell", "fallen", "falls", "tripped", "slipped"], "fell": ["fall", "fallen"], "fallen": ["fall", "fell"],
            "falls": ["fall", "fell"], "tripped": ["fall", "fell"], "slipped": ["fall", "fell"],
            "drink": drinks, "drinks": drinks, "drank": drinks, "drinking": drinks,
            "food": foods, "ate": foods, "eat": foods, "eaten": foods, "meal": foods, "meals": foods,
            "walk": ["walked", "walking", "steps", "exercise"], "walked": ["walk", "walking"], "walking": ["walk", "walked"],
            "exercise": ["walk", "walked", "run", "ran", "gym", "workout"],
        ]
        var expanded = q
        for w in q { for s in synonyms[w] ?? [] { expanded.insert(s) } }
        let scored = facts.map { f -> (MemoryFact, Int) in (f, Self.words(f.text).intersection(expanded).count) }
        let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.createdAt > $1.0.createdAt }.map { $0.0 }
        if !hits.isEmpty { return Array(hits.prefix(limit)) }
        return q.isEmpty ? Array(facts.sorted { $0.createdAt > $1.createdAt }.prefix(limit)) : []
    }

    /// Picks out statements worth remembering from a chat message, without a model.
    /// Example: "I slept 5 hours last night and had coffee at 9" -> one fact per clause.
    public static func extractFacts(from message: String) -> [String] {
        let lower = message.lowercased()
        if lower.hasPrefix("remember") {
            let t = message.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
            let cleaned = t.hasPrefix("that ") ? String(t.dropFirst(5)) : t
            return cleaned.isEmpty ? [] : [cleaned.prefix(1).uppercased() + cleaned.dropFirst()]
        }
        let cues = ["i slept", "i didn't sleep", "i did not sleep", "i had ", "i've had", "i just had", "i drank", "i ate", "i took ", "i skipped",
                    "i didn't eat", "i went for", "i went to the gym", "i fell", "i've fallen", "i tripped", "i slipped", "i hurt my", "i injured", "i bumped", "i hit my", "i ran", "i run", "i worked out", "i'm sick", "i am sick", "i have a headache",
                    "i'm stressed", "i am stressed", "i feel", "i'm feeling", "i've been", "my period", "i'm on my period", "i take ", "i'm training", "i am training", "i have a ", "i'm allergic", "i usually"]
        let clauses = message.components(separatedBy: CharacterSet(charactersIn: ".,;!?\n")).flatMap { $0.components(separatedBy: " and ") }
        var out: [String] = []
        for c in clauses {
            let whole = c.trimmingCharacters(in: .whitespaces)
            let l = whole.lowercased()
            // The statement can sit inside a question ("is it because I drank coffee earlier?"):
            // keep it from the cue onward.
            let hits = cues.compactMap { cue -> String.Index? in
                guard let r = l.range(of: cue) else { return nil }
                return (r.lowerBound == l.startIndex || l[l.index(before: r.lowerBound)] == " ") ? r.lowerBound : nil
            }
            guard let start = hits.min() else { continue }
            let offset = min(l.distance(from: l.startIndex, to: start), whole.count)
            let t = String(whole[whole.index(whole.startIndex, offsetBy: offset)...]).trimmingCharacters(in: .whitespaces)
            guard t.count >= 8, t.count <= 140 else { continue }
            out.append(t.prefix(1).uppercased() + t.dropFirst())
        }
        return out
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e }()
}
extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
