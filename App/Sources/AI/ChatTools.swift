import Foundation
import LiteRTLM
import BoltCore

/// LiteRT-LM creates tool structs with `init()`, so they reach app state through this bridge.
/// Every call runs the evidence function on the main actor and logs itself for the trace screen.
final class ToolBridge: @unchecked Sendable {
    static let shared = ToolBridge()
    /// Set by AppModel. Builds the evidence functions over the current live state.
    @MainActor var makeTools: (() -> HealthTools)?
    /// Set by AppModel. Records a tool call (name, arguments, result, ms).
    @MainActor var onCall: ((String, String, String, Double) -> Void)?

    /// Returns a JSON object (dictionary) so the model sees structured fields, not an escaped string.
    func run(_ name: String, args: String, _ body: @escaping @MainActor (HealthTools) -> [String: Any]) async -> Any {
        let t0 = Date()
        AppModel.appendTraceFile("tool | start \(name)(\(args))")
        let result: String = await MainActor.run {
            guard let tools = self.makeTools?() else { return "{\"error\":\"live data unavailable\"}" }
            return HealthTools.json(body(tools))
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        await MainActor.run { self.onCall?(name, args, result, ms) }
        if let data = result.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) { return obj }
        return result
    }
}

struct GetLiveMetricsTool: Tool {
    static let name = "get_live_metrics"
    static let description = "Latest and average heart rate, SpO2, skin temperature, activity and the user's personal resting baseline from the user's wearable band."
    @ToolParam(description: "How many seconds of recent data to summarize, e.g. 60")
    var windowSeconds: Int = 60
    init() {}
    func run() async throws -> Any {
        let w = windowSeconds
        return await ToolBridge.shared.run(Self.name, args: "window_seconds=\(w)") { $0.liveMetrics(windowSeconds: w) }
    }
}

struct GetTrendTool: Tool {
    static let name = "get_trend"
    static let description = "How one metric changed over recent minutes: min, max, mean, change per minute and up to 12 points."
    @ToolParam(description: "One of: heart_rate, spo2, skin_temp, motion")
    var metric: String = "heart_rate"
    @ToolParam(description: "How many minutes back to look, 1 to 60")
    var minutes: Int = 10
    init() {}
    func run() async throws -> Any {
        let m = metric, n = minutes
        return await ToolBridge.shared.run(Self.name, args: "metric=\(m), minutes=\(n)") { $0.trend(metric: m, minutes: n) }
    }
}

struct GetActivityTimelineTool: Tool {
    static let name = "get_activity_timeline"
    static let description = "What the user has been doing (still, walking, running, moving) over recent minutes, with average heart rate per segment."
    @ToolParam(description: "How many minutes back to look, 1 to 60")
    var minutes: Int = 15
    init() {}
    func run() async throws -> Any {
        let n = minutes
        return await ToolBridge.shared.run(Self.name, args: "minutes=\(n)") { $0.activityTimeline(minutes: n) }
    }
}

struct GetRecentInsightsTool: Tool {
    static let name = "get_recent_insights"
    static let description = "Recent events the band detected and insights shown (falls, workouts, heart-rate alerts), with times, newest first. Use for questions like did I fall or what happened today."
    @ToolParam(description: "How many events, 8 to 12")
    var count: Int = 10
    init() {}
    func run() async throws -> Any {
        let n = count
        return await ToolBridge.shared.run(Self.name, args: "count=\(n)") { $0.recentInsights(count: n) }
    }
}

struct RecallMemoryTool: Tool {
    static let name = "recall_memory"
    static let description = "Facts the user has told Bolt before, such as sleep, caffeine, training, cycle or how they feel."
    @ToolParam(description: "What to look for, e.g. sleep, coffee, training")
    var query: String = ""
    init() {}
    func run() async throws -> Any {
        let q = query
        return await ToolBridge.shared.run(Self.name, args: "query=\(q)") { $0.recallMemory(query: q) }
    }
}

struct GetHistoryTool: Tool {
    static let name = "get_history"
    static let description = "Stored band history for one metric over the past hours (kept across app restarts): overall mean, min, max and time buckets. Use for earlier today, last night or the past few days."
    @ToolParam(description: "One of: heart_rate, spo2, skin_temp, motion")
    var metric: String = "heart_rate"
    @ToolParam(description: "How many hours back, 1 to 168")
    var hours: Int = 24
    init() {}
    func run() async throws -> Any {
        let m = metric, h = hours
        return await ToolBridge.shared.run(Self.name, args: "metric=\(m), hours=\(h)") { $0.history(metric: m, hours: h) }
    }
}

struct GetDailySummaryTool: Tool {
    static let name = "get_daily_summary"
    static let description = "One row per day from stored band history: time worn, mean and resting heart rate, SpO2, skin temperature, steps and active minutes. Use to compare days."
    @ToolParam(description: "How many days back including today, 1 to 14")
    var days: Int = 7
    init() {}
    func run() async throws -> Any {
        let d = days
        return await ToolBridge.shared.run(Self.name, args: "days=\(d)") { $0.dailySummary(days: d) }
    }
}

struct SaveMemoryTool: Tool {
    static let name = "save_memory"
    static let description = "Remember something the user told you about themselves (food, coffee, alcohol, sleep, exercise, symptoms, medication, cycle, mood) so you can use it later."
    @ToolParam(description: "One short first-person sentence, e.g. I drank two coffees this morning")
    var fact: String = ""
    init() {}
    func run() async throws -> Any {
        let f = fact
        return await ToolBridge.shared.run(Self.name, args: "fact=\(f)") { $0.saveMemory(fact: f) }
    }
}

enum ChatToolset {
    static func all() -> [Tool] {
        [GetLiveMetricsTool(), GetTrendTool(), GetActivityTimelineTool(), GetHistoryTool(), GetDailySummaryTool(), GetRecentInsightsTool(), RecallMemoryTool(), SaveMemoryTool()]
    }
}
