import Foundation

/// One decoded item from a data source (live Bluetooth, a recorded session, or the synthetic demo).
public enum LiveInput: Sendable {
    case cardiac(CardiacReading)
    case imu([IMUSample])
    case temperature(TemperatureSample)
    case wear(WearStatusSample)
}

public enum ActivityClass: Int, CaseIterable, Codable, Sendable {
    case stationary = 0, generalMovement = 1, walk = 2, run = 3, cycle = 4, stairs = 5

    /// Canonical class order.
    public static let modelOrder: [ActivityClass] = [.stationary, .generalMovement, .walk, .run, .cycle, .stairs]

    public var label: String {
        switch self {
        case .stationary: return "Still"
        case .generalMovement: return "Moving"
        case .walk: return "Walking"
        case .run: return "Running"
        case .cycle: return "Cycling"
        case .stairs: return "Walking"   // folded into walk downstream, as in the pipeline
        }
    }

    public var isActive: Bool { self != .stationary }
    public var symbol: String {
        switch self {
        case .stationary: return "figure.stand"
        case .generalMovement: return "figure.mixed.cardio"
        case .walk, .stairs: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "figure.outdoor.cycle"
        }
    }
}

public struct CardiacPoint: Codable, Sendable, Equatable {
    public var t: Date
    public var hr: Double?
    public var rmssd: Double?
    public var spo2: Double?
    public var validPermille: Int
    /// What the band sent before range and confidence checks, and its reason codes (debug log only).
    public var rawHR: Double?
    public var hrReason: Int?
    public var hrvReason: Int?
    public init(t: Date, hr: Double?, rmssd: Double?, spo2: Double?, validPermille: Int,
                rawHR: Double? = nil, hrReason: Int? = nil, hrvReason: Int? = nil) {
        self.t = t; self.hr = hr; self.rmssd = rmssd; self.spo2 = spo2; self.validPermille = validPermille
        self.rawHR = rawHR; self.hrReason = hrReason; self.hrvReason = hrvReason
    }
}

public struct ScalarPoint: Codable, Sendable, Equatable {
    public var t: Date
    public var value: Double
    public init(t: Date, value: Double) { self.t = t; self.value = value }
}

public struct AccelPoint: Sendable, Equatable {
    public var t: Date
    public var x: Double, y: Double, z: Double   // in g
    public init(t: Date, x: Double, y: Double, z: Double) { self.t = t; self.x = x; self.y = y; self.z = z }
    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

public struct ActivityPoint: Codable, Sendable, Equatable {
    public var t: Date
    public var activity: ActivityClass
    public var probability: Double
    public init(t: Date, activity: ActivityClass, probability: Double) { self.t = t; self.activity = activity; self.probability = probability }
}

public enum Metric: String, CaseIterable, Codable, Sendable {
    case heartRate = "heart_rate", hrv = "hrv", spo2 = "spo2", skinTemp = "skin_temp", motion = "motion"
    public var unit: String {
        switch self {
        case .heartRate: return "bpm"
        case .hrv: return "ms"
        case .spo2: return "%"
        case .skinTemp: return "°C"
        case .motion: return "g"
        }
    }
    public var label: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .hrv: return "HRV (RMSSD)"
        case .spo2: return "SpO2"
        case .skinTemp: return "Skin temperature"
        case .motion: return "Motion"
        }
    }
    /// Accepts loose names the model might use in a tool call.
    public init?(loose: String) {
        let s = loose.lowercased().replacingOccurrences(of: " ", with: "_")
        switch s {
        case "heart_rate", "hr", "heartrate", "pulse", "bpm": self = .heartRate
        case "hrv", "rmssd", "heart_rate_variability": self = .hrv
        case "spo2", "oxygen", "blood_oxygen", "sp02": self = .spo2
        case "skin_temp", "temperature", "temp", "skin_temperature", "wrist_temperature": self = .skinTemp
        case "motion", "movement", "accel", "activity_level": self = .motion
        default: return nil
        }
    }
}

public struct WindowStats: Sendable, Equatable {
    public var count: Int
    public var mean: Double
    public var min: Double
    public var max: Double
    public var latest: Double
    /// Least-squares slope in units per minute.
    public var slopePerMinute: Double
}

public enum Stats {
    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    public static func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
    public static func std(_ xs: [Double]) -> Double? {
        guard xs.count > 1, let m = mean(xs) else { return nil }
        return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)).squareRoot()
    }
    public static func slopePerMinute(_ pts: [ScalarPoint]) -> Double {
        guard pts.count > 1 else { return 0 }
        let t0 = pts[0].t
        let xs = pts.map { $0.t.timeIntervalSince(t0) / 60 }, ys = pts.map { $0.value }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        return den > 0 ? num / den : 0
    }
}

/// Rounds for display and for prompts, so the model and the UI see the same numbers.
public enum Fmt {
    public static func n(_ v: Double, _ digits: Int = 0) -> String {
        if digits == 0 { return String(Int(v.rounded())) }
        return String(format: "%.\(digits)f", v)
    }
}
