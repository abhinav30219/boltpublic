import Foundation

public enum ActivityMath {
    public static func softmax(_ logits: [Float]) -> [Double] {
        guard let m = logits.max() else { return [] }
        let e = logits.map { Double(exp($0 - m)) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }

    /// Picks the top class from the fitness model's 6 logits. Stairs is folded into walk, as downstream.
    public static func classify(logits: [Float]) -> (ActivityClass, Double)? {
        guard logits.count == ActivityClass.modelOrder.count else { return nil }
        var p = softmax(logits)
        p[2] += p[5]; p[5] = 0
        guard let i = p.indices.max(by: { p[$0] < p[$1] }) else { return nil }
        return (ActivityClass.modelOrder[i], p[i])
    }

    /// Fallback when the LiteRT activity model isn't available: motion-energy thresholds on the
    /// 30 s window. Clearly cruder than the model; used only so the app keeps working.
    public static func heuristic(window: [[Float]]) -> (ActivityClass, Double) {
        guard window.count == 3, !window[0].isEmpty else { return (.stationary, 0.5) }
        let mags = (0..<window[0].count).map { i -> Double in
            let x = Double(window[0][i]), y = Double(window[1][i]), z = Double(window[2][i])
            return (x * x + y * y + z * z).squareRoot()
        }
        let s = Stats.std(mags) ?? 0
        switch s {
        case ..<0.03: return (.stationary, 0.85)
        case ..<0.12: return (.generalMovement, 0.72)
        case ..<0.45: return (.walk, 0.72)
        default: return (.run, 0.75)
        }
    }
}

/// Only switches class after two consecutive confident windows, so cards don't flap.
public struct ActivitySmoother: Sendable {
    public var minProbability: Double = 0.7
    public var requiredRepeats = 2
    public private(set) var current: ActivityClass?
    private var candidate: ActivityClass?
    private var candidateCount = 0

    public init() {}

    /// Returns the new class when the smoothed activity changes, else nil.
    public mutating func update(_ cls: ActivityClass, probability: Double) -> ActivityClass? {
        guard probability >= minProbability else { return nil }
        if current == nil { current = cls; return nil }
        if cls.label == current!.label { candidate = nil; candidateCount = 0; return nil }
        if cls.label == candidate?.label { candidateCount += 1 } else { candidate = cls; candidateCount = 1 }
        if candidateCount >= requiredRepeats {
            current = cls; candidate = nil; candidateCount = 0
            return cls
        }
        return nil
    }
}
