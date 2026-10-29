import Foundation

/// A plain word for a metric value, shown on the Home cards for older users.
public struct Meaning: Equatable, Sendable {
    public var word: String
    public var isAlert: Bool
    public init(word: String, isAlert: Bool = false) {
        self.word = word
        self.isAlert = isAlert
    }
}

/// Turns a metric value plus the user's baseline into a plain word.
/// Every threshold comes from `CompanionTuning` / `TriggerConfig`.
public enum MetricMeaning {
    public static func heart(_ hr: Double, baseline: Double?,
                             tuning: CompanionTuning = .init(),
                             safety: TriggerConfig = .init()) -> Meaning {
        if hr >= safety.safetyHRAtRest { return Meaning(word: "Check", isAlert: true) }
        if let baseline, hr >= baseline + tuning.meaningBusyAboveBaselineBpm { return Meaning(word: "Busy") }
        return Meaning(word: "Calm")
    }

    public static func steps(_ steps: Int, goal: Int) -> Meaning {
        if steps >= goal { return Meaning(word: "Goal met") }
        if steps >= goal / 2 { return Meaning(word: "Good day") }
        return Meaning(word: "Getting going")
    }

    public static func energy(_ kcal: Double, tuning: CompanionTuning = .init()) -> Meaning {
        Meaning(word: kcal >= tuning.meaningActiveKcal ? "Active" : "Easy day")
    }

    public static func relaxation(_ hrv: Double, baseline: Double?,
                                  tuning: CompanionTuning = .init()) -> Meaning {
        guard let baseline else { return Meaning(word: "Rested") }
        return Meaning(word: hrv >= baseline * tuning.meaningRestedFractionOfBaseline ? "Rested" : "Low")
    }

    public static func oxygen(_ spo2: Double,
                              tuning: CompanionTuning = .init(),
                              safety: TriggerConfig = .init()) -> Meaning {
        if spo2 < safety.safetySpO2 { return Meaning(word: "Check", isAlert: true) }
        if spo2 < tuning.meaningOxygenLowPct { return Meaning(word: "Low") }
        return Meaning(word: "Normal")
    }

    public static func skinTemp(_ c: Double, baseline: Double?, shift: Double) -> Meaning {
        guard let baseline else { return Meaning(word: "Steady") }
        if c > baseline + shift { return Meaning(word: "Warmer") }
        if c < baseline - shift { return Meaning(word: "Cooler") }
        return Meaning(word: "Steady")
    }
}
