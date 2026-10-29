import Foundation

/// Where the spoken fall script is. The lines are fixed text, never written by Gemma.
public enum FallStage: Equatable, Sendable {
    case asking, reasked, alarm, resolvedOK
}

/// The fall script: what the robot (or the phone) says at each stage, and when the stages change.
/// Pure and Foundation-only. Every line passes `RobotCommand.say` (no double quote, no newline).
public struct FallScript: Sendable {
    public init() {}

    /// The line for `stage`. `name` is the profile name; only the first word is used.
    /// The wording is gender-neutral ("Please come and help!") because the profile has no pronouns.
    public func line(for stage: FallStage, name: String?) -> String {
        let first = Self.firstName(name)
        switch stage {
        case .asking:
            return Self.addressed(first, "are you okay? It looks like you fell. If you're okay, tap I'm okay on your phone.")
        case .reasked:
            return Self.addressed(first, "are you okay? Tap I'm okay on your phone.")
        case .alarm:
            return "Help! Help! \(first ?? "Someone") has fallen! Please come and help!"
        case .resolvedOK:
            return "I'm glad you're okay. I'll keep an eye on you."
        }
    }

    /// The stage `sinceAlert` seconds after the fall check opened. Resolved beats everything; a request
    /// for help goes straight to the alarm; otherwise 0 asks, `reaskSeconds` re-asks, and
    /// `responseTimeoutSeconds` sounds the alarm.
    public func stage(sinceAlert: TimeInterval, helpRequested: Bool, resolved: Bool, tuning: FallTuning) -> FallStage {
        if resolved { return .resolvedOK }
        if helpRequested || sinceAlert >= tuning.responseTimeoutSeconds { return .alarm }
        if sinceAlert >= tuning.reaskSeconds { return .reasked }
        return .asking
    }

    /// True when the alarm line should be said again.
    public func alarmRepeatDue(secondsSinceLastLine: TimeInterval, tuning: FallTuning) -> Bool {
        secondsSinceLastLine >= tuning.alarmRepeatSeconds
    }

    // MARK: names

    /// First word of the name with quotes and line breaks removed; nil when nothing is left.
    static func firstName(_ name: String?) -> String? {
        let banned = CharacterSet(charactersIn: "\"\u{201C}\u{201D}\u{201E}\u{2033}").union(.newlines).union(.controlCharacters)
        let cleaned = String(String.UnicodeScalarView((name ?? "").unicodeScalars.filter { !banned.contains($0) }))
        let word = cleaned.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        return word?.isEmpty == false ? word : nil
    }

    /// "<Name>, <rest>" or the capitalised rest when there is no name.
    private static func addressed(_ name: String?, _ rest: String) -> String {
        if let name { return "\(name), \(rest)" }
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }
}
