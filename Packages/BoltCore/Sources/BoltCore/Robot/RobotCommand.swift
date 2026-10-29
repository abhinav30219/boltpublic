import Foundation

/// GATT identifiers for the Quaddle robot: the standard Nordic UART service
/// (`tools/quaddle_ble.py`). RX is the robot's input (we write), TX its output (we subscribe).
public enum RobotUUIDs {
    public static let uartService = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
    public static let uartRX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
    public static let uartTX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

    /// Advertised name of the demo robot.
    public static let defaultName = "QUADDLE55_BLE"

    /// Any advertised name containing "quaddle", case-insensitively.
    public static func isRobotName(_ name: String?) -> Bool {
        (name ?? "").lowercased().contains("quaddle")
    }
}

/// One command for the Quaddle robot. Text commands are written as UTF-8 plus
/// a newline; binary packets are written as-is (token through `~` terminator).
public enum RobotCommand: Equatable, Sendable {
    case text(String)
    case binary([UInt8])

    /// Wi-Fi status and IP. Tested.
    public static let queryWiFi = RobotCommand.text("w")
    /// Stand; also ends walking. Tested.
    public static let stand = RobotCommand.text("kup")
    /// Rest posture. Tested.
    public static let rest = RobotCommand.text("krest")

    /// Walk forward `cycles` gait cycles, then stand. Tested with 1.
    public static func walkForward(cycles: Int = 1) -> RobotCommand { .text("kwkF \(max(1, cycles))") }
    /// Walk backward `cycles` gait cycles, then stand. Tested with 1.
    public static func walkBackward(cycles: Int = 1) -> RobotCommand { .text("kwkB \(max(1, cycles))") }

    /// Flip/roll skill. User-confirmed.
    public static let flipRoll = RobotCommand.text("kflipRoll")

    /// Speak `text` aloud: `>> say "<text>"`, relayed by the Motion Core to the
    /// AI Core's speaker. nil when the text is blank, has a newline or NUL, or
    /// has a double quote (quote escaping isn't documented).
    public static func say(_ text: String) -> RobotCommand? {
        guard isRelayable(text), !text.contains("\"") else { return nil }
        return .text(#">> say ""# + text + #"""#)
    }

    /// Send `prompt` to the robot's AI: `>> <prompt>`. The AI may answer aloud
    /// or trigger robot actions. nil when blank or containing a newline or NUL.
    public static func ask(_ prompt: String) -> RobotCommand? {
        guard isRelayable(prompt) else { return nil }
        return .text(">> " + prompt)
    }

    private static func isRelayable(_ text: String) -> Bool {
        // Scalars, not Characters: "\r\n" is a single Character in Swift.
        !text.trimmingCharacters(in: .whitespaces).isEmpty && !text.unicodeScalars.contains { "\n\r\0".unicodeScalars.contains($0) }
    }

    /// Binary `Jr x y ~`: gaze input; also leans the body and pans an attached head.
    /// From CamWalkingGame's hardware notes; not tested here.
    public static func gaze(x: Int8, y: Int8) -> RobotCommand {
        .binary([0x4A, 0x72, UInt8(bitPattern: x), UInt8(bitPattern: y), 0x7E])
    }

    /// Binary `I joint angle … ~`: set several joint angles at once.
    /// From CamWalkingGame's control code; not tested here.
    public static func joints(_ pairs: [(joint: UInt8, angle: Int8)]) -> RobotCommand {
        .binary([0x49] + pairs.flatMap { [$0.joint, UInt8(bitPattern: $0.angle)] } + [0x7E])
    }

    /// The bytes written to the UART RX characteristic in one write.
    public var payload: Data {
        switch self {
        case .text(let s): return Data((s + "\n").utf8)
        case .binary(let bytes): return Data(bytes)
        }
    }

    /// Short label for the trace.
    public var label: String {
        switch self {
        case .text(let s): return s
        case .binary(let bytes): return "binary " + bytes.map { String(Int8(bitPattern: $0)) }.joined(separator: " ")
        }
    }
}

/// Collects the robot's UART notifications for one command. The UART has no
/// completion message, so like `quaddle_ble.py` a command is done when the
/// robot goes quiet after replying, or when the listen window runs out.
public struct RobotReplyCollector: Sendable {
    /// Seconds of silence after the last notification that end the reply.
    public var quietSeconds: TimeInterval
    /// Longest time to listen after the write.
    public var listenSeconds: TimeInterval

    public let sentAt: Date
    public private(set) var lastReplyAt: Date?
    /// Complete lines received so far, without line endings or blank lines.
    public private(set) var lines: [String] = []
    private var partial = Data()

    public init(sentAt: Date, quietSeconds: TimeInterval = 1.5, listenSeconds: TimeInterval = 8) {
        self.sentAt = sentAt; self.quietSeconds = quietSeconds; self.listenSeconds = listenSeconds
    }

    public var gotReply: Bool { lastReplyAt != nil }

    /// Feeds one notification; replies can be split across notifications or carry several lines.
    public mutating func add(_ data: Data, at date: Date) {
        lastReplyAt = date
        partial.append(data)
        while let i = partial.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            append(partial[partial.startIndex..<i])
            partial = Data(partial[partial.index(after: i)...])
        }
    }

    public func isDone(at date: Date) -> Bool {
        if date.timeIntervalSince(sentAt) >= listenSeconds { return true }
        guard let last = lastReplyAt else { return false }
        return date.timeIntervalSince(last) >= quietSeconds
    }

    /// Every line, including a trailing one with no newline yet.
    public var allLines: [String] {
        var out = lines
        let tail = String(decoding: partial, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    private mutating func append(_ bytes: Data) {
        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { lines.append(line) }
    }
}
