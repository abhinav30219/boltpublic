import Foundation

/// What the detector saw around a candidate fall.
public struct FallEvent: Sendable, Equatable {
    public var at: Date
    /// Rough 0...1 confidence from the heuristic below (not a calibrated probability).
    public var probability: Double
    /// Largest acceleration magnitude in the impact, in g.
    public var peakG: Double
    /// How far the gravity direction turned between before the impact and 1 to 3 s after, in degrees.
    public var orientationChangeDeg: Double
    /// Spread of |a| from 1 to 3 s after the impact (low = lying still), in g.
    public var stillnessSD: Double
    public var saturated: Bool
    public init(at: Date, probability: Double, peakG: Double, orientationChangeDeg: Double, stillnessSD: Double, saturated: Bool = false) {
        self.at = at; self.probability = probability; self.peakG = peakG
        self.orientationChangeDeg = orientationChangeDeg; self.stillnessSD = stillnessSD; self.saturated = saturated
    }
}

/// One evaluated impact, kept for the Motion test screen and the trace.
public struct FallDecision: Sendable, Equatable {
    public var at: Date
    public var features: FallDetector.Features
    public var probability: Double
    public var isFall: Bool
    public init(at: Date, features: FallDetector.Features, probability: Double, isFall: Bool) {
        self.at = at; self.features = features; self.probability = probability; self.isFall = isFall
    }
}

/// A basic, generic fall heuristic on phone / wrist accelerometer (in g). It is intentionally simple
/// and is NOT a medical fall detector: it flags a hard impact (a large acceleration spike) followed by
/// the device lying relatively still and reoriented. There are no fitted model weights here.
public final class FallDetector {
    public struct Features: Sendable, Equatable {
        public var peak: Double
        public var turn: Double
        public var postSD: Double
        public var energy: Double
        public var preSD: Double
        public init(peak: Double = 0, turn: Double = 0, postSD: Double = 0, energy: Double = 0, preSD: Double = 0) {
            self.peak = peak; self.turn = turn; self.postSD = postSD; self.energy = energy; self.preSD = preSD
        }
    }

    public var candidateG = 2.3
    public var refractory: TimeInterval = 30
    /// Impact must be at least this hard (g) and the device must be this still afterwards (g std).
    public var minPeakG = 2.6
    public var maxStillSD = 0.25
    public var minTurnDeg = 35.0

    private var scannedUntil: Date?
    private var lastFall: Date?

    public private(set) var estimatedDecision: FallDecision?
    // Diagnostics for the Motion test screen.
    public private(set) var estimatedRateHz: Double = 0
    public private(set) var maxMagnitudeSeen: Double = 0
    public private(set) var recentDecisions: [FallDecision] = []

    public init() {}

    public func reset() {
        scannedUntil = nil; lastFall = nil; estimatedDecision = nil
        estimatedRateHz = 0; maxMagnitudeSeen = 0; recentDecisions = []
    }

    /// Feed the most recent accel window (g). Returns a fall event when one is detected.
    public func feed(_ points: [AccelPoint]) -> FallEvent? {
        guard let last = points.last?.t else { return nil }
        if let first = points.first?.t, points.count > 1 {
            let span = last.timeIntervalSince(first)
            if span > 0 { estimatedRateHz = Double(points.count - 1) / span }
        }
        maxMagnitudeSeen = max(maxMagnitudeSeen, points.map { $0.magnitude }.max() ?? 0)
        let candidates = points.filter { p in
            p.magnitude >= candidateG &&
            !points.contains { abs($0.t.timeIntervalSince(p.t)) <= 1 && $0.magnitude > p.magnitude }
        }
        for c in candidates {
            if let s = scannedUntil, c.t <= s { continue }
            guard last.timeIntervalSince(c.t) >= 3 else { continue }   // wait for the post window
            scannedUntil = c.t
            if let lf = lastFall, c.t.timeIntervalSince(lf) < refractory { continue }
            guard let f = Self.features(points, at: c.t) else { continue }
            let isFall = f.peak >= minPeakG && f.postSD <= maxStillSD && f.turn >= minTurnDeg
            let prob = isFall ? min(1, 0.5 + (f.peak - minPeakG) * 0.15) : 0.2
            let decision = FallDecision(at: c.t, features: f, probability: prob, isFall: isFall)
            estimatedDecision = decision
            recentDecisions.append(decision)
            if recentDecisions.count > 20 { recentDecisions.removeFirst(recentDecisions.count - 20) }
            if isFall {
                lastFall = c.t
                return FallEvent(at: c.t, probability: prob, peakG: f.peak,
                                 orientationChangeDeg: f.turn, stillnessSD: f.postSD, saturated: f.peak >= 5.7)
            }
        }
        return nil
    }
}
