import Foundation

public enum WristGesture: String, Sendable, Equatable {
    /// Hand waved side to side, a few times a second.
    case wave
    /// Shaken fast or very hard.
    case shake
}

public struct GestureEvent: Sendable, Equatable {
    public var gesture: WristGesture
    public var at: Date
    public var cycles: Double
    public var frequencyHz: Double
    public var amplitudeG: Double
    public init(gesture: WristGesture, at: Date, cycles: Double, frequencyHz: Double, amplitudeG: Double) {
        self.gesture = gesture; self.at = at; self.cycles = cycles; self.frequencyHz = frequencyHz; self.amplitudeG = amplitudeG
    }
}

/// One analysed motion burst, for the debug log.
public struct GestureBurst: Sendable, Equatable {
    public var at: Date
    public var verdict: String
    public var seconds: Double
    public var cycles: Double
    public var frequencyHz: Double
    public var amplitudeG: Double
}

/// Spots deliberate shake / wave gestures in accelerometer data (in g). A gesture is a short burst of
/// back-and-forth motion between two still moments: a quiet period, then a burst with several evenly
/// spaced swings, then quiet again. Walking and fidgeting don't start and stop like that. This is a
/// plain heuristic with no tuned model: the axis that moves most is high-passed and its alternating
/// peaks counted.
public final class GestureDetector {
    public struct Config: Sendable {
        public var quietStdG = 0.08
        public var activeStdG = 0.15
        public var quietBefore: TimeInterval = 0.6
        public var quietAfter: TimeInterval = 0.4
        public var minBurst: TimeInterval = 0.7
        public var maxBurst: TimeInterval = 4.0
        public var peakG = 0.12
        public var refractory: TimeInterval = 4
        public var waveMinSwings = 5
        public var waveHz: ClosedRange<Double> = 1.5...4.5
        public var waveMinAmpG = 0.8
        public var shakeMinSwings = 6
        public var shakeMinHz = 5.0
        public var shakeMinAmpG = 1.0
        public init() {}
    }

    public var config = Config()
    /// Called for every burst evaluated (debug).
    public var onBurst: ((GestureBurst, [AccelPoint]) -> Void)?
    /// Recent evaluated bursts, for the Motion test screen.
    public private(set) var recentBursts: [GestureBurst] = []

    private var lastGesture: Date?

    public init() {}

    public func reset() { lastGesture = nil; recentBursts = [] }

    /// Feed the most recent accel window (g). Returns a gesture when the burst qualifies.
    public func feed(_ points: [AccelPoint]) -> GestureEvent? {
        guard points.count >= 8, let last = points.last?.t else { return nil }
        if let lg = lastGesture, last.timeIntervalSince(lg) < config.refractory { return nil }

        // Overall spread per axis; use the busiest axis.
        let axes = [points.map(\.x), points.map(\.y), points.map(\.z)]
        func sd(_ xs: [Double]) -> Double {
            let mu = xs.reduce(0, +) / Double(xs.count)
            return (xs.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Double(xs.count)).squareRoot()
        }
        let busiest = axes.max(by: { sd($0) < sd($1) }) ?? axes[0]
        let spread = sd(busiest)
        guard spread >= config.activeStdG else { return nil }

        // High-pass: subtract the mean, then count sign-changing peaks above peakG.
        let mu = busiest.reduce(0, +) / Double(busiest.count)
        let hp = busiest.map { $0 - mu }
        var swings = 0
        var lastSign = 0
        var amp = 0.0
        for v in hp where abs(v) >= config.peakG {
            let sign = v > 0 ? 1 : -1
            if sign != lastSign && lastSign != 0 { swings += 1 }
            lastSign = sign
            amp = max(amp, abs(v))
        }
        let seconds = points.last!.t.timeIntervalSince(points.first!.t)
        guard seconds >= config.minBurst, seconds <= config.maxBurst else { return nil }
        let cycles = Double(swings) / 2
        let hz = seconds > 0 ? Double(swings) / 2 / seconds : 0

        var verdict = "none"
        var gesture: WristGesture?
        if swings >= config.shakeMinSwings, hz >= config.shakeMinHz, amp >= config.shakeMinAmpG {
            gesture = .shake; verdict = "shake"
        } else if swings >= config.waveMinSwings, config.waveHz.contains(hz), amp >= config.waveMinAmpG {
            gesture = .wave; verdict = "wave"
        }
        let burst = GestureBurst(at: last, verdict: verdict, seconds: seconds, cycles: cycles, frequencyHz: hz, amplitudeG: amp)
        recentBursts.append(burst)
        if recentBursts.count > 20 { recentBursts.removeFirst(recentBursts.count - 20) }
        onBurst?(burst, points)
        guard let g = gesture else { return nil }
        lastGesture = last
        return GestureEvent(gesture: g, at: last, cycles: cycles, frequencyHz: hz, amplitudeG: amp)
    }

    /// A synthetic wave or shake for the simulate buttons and tests.
    public static func synthetic(_ gesture: WristGesture, start: Date, rateHz: Double = 50) -> [AccelPoint] {
        var out: [AccelPoint] = []
        let dt = 1 / rateHz
        var t = 0.0
        func add(_ x: Double, _ y: Double, _ z: Double) { out.append(AccelPoint(t: start.addingTimeInterval(t), x: x, y: y, z: z)); t += dt }
        let hz = gesture == .wave ? 2.6 : 6.0
        let amp = gesture == .wave ? 0.95 : 1.3
        while t < 0.7 { add(0.02, 0.02, 0.99) }                              // quiet before
        let burstEnd = t + 1.6
        while t < burstEnd { add(amp * sin(2 * .pi * hz * t), 0.03, 0.99) }  // burst on x
        let end = t + 0.6
        while t < end { add(0.02, 0.02, 0.99) }                             // quiet after
        return out
    }
}
