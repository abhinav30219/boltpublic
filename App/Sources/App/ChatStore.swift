import Foundation
import BoltCore

/// One saved conversation with Gemma.
struct ChatThread: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [ChatMessage] = []
    /// Gemma's running summary of the turns that have left the recent window.
    var summary = ""
    /// How many finished turns `summary` covers.
    var summarizedTurns = 0

    /// Finished question/answer pairs, oldest first (errors and stopped answers are skipped).
    var turns: [ChatTurn] {
        var out: [ChatTurn] = []
        var pending: String?
        for m in messages {
            if m.role == .user { pending = m.text; continue }
            if let q = pending, !m.text.isEmpty, m.error == nil, !m.isStreaming { out.append(ChatTurn(question: q, answer: m.text)) }
            pending = nil
        }
        return out
    }

    /// A line for other chats' context and the history list.
    var gist: String {
        if !summary.isEmpty { return summary.count <= 160 ? summary : String(summary.prefix(160)) + "…" }
        return turns.last.map { "asked \"\($0.question.prefix(80))\"" } ?? ""
    }
}

extension ChatThread {
    enum CodingKeys: String, CodingKey { case id, title, createdAt, updatedAt, messages, summary, summarizedTurns }

    /// Tolerant decoding: a field added or missing in another app version must not drop the saved chat.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Chat"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summarizedTurns = try c.decodeIfPresent(Int.self, forKey: .summarizedTurns) ?? 0
    }
}

/// Chats on disk, one JSON file each, in Application Support/Bolt/chats.
final class ChatStore {
    private let dir: URL
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    init(directory: URL) {
        dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func loadAll() -> [ChatThread] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ChatThread.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ t: ChatThread) {
        var copy = t
        // Never persist a half-streamed answer as if it were finished.
        for i in copy.messages.indices where copy.messages[i].isStreaming { copy.messages[i].isStreaming = false }
        if let data = try? encoder.encode(copy) { try? data.write(to: dir.appendingPathComponent("\(t.id.uuidString).json"), options: .atomic) }
    }

    func delete(_ id: UUID) {
        // Deletion is a rename into a trash folder so nothing is lost by a mis-swipe during the demo.
        let src = dir.appendingPathComponent("\(id.uuidString).json")
        let trash = dir.appendingPathComponent("deleted", isDirectory: true)
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: src, to: trash.appendingPathComponent(src.lastPathComponent))
    }
}
