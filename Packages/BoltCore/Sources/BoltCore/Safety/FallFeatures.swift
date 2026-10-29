import Foundation

extension FallDetector {
    public static func features(_ pts: [AccelPoint], at t: Date) -> Features? {
        func win(_ a: Double, _ b: Double) -> [AccelPoint] {
            pts.filter { let d = $0.t.timeIntervalSince(t); return d >= a && d <= b }
        }
        let pre = win(-2.5, -0.6), post = win(1.0, 3.0), imp = win(-0.5, 0.5)
        guard pre.count >= 3, post.count >= 3, imp.count >= 2 else { return nil }
        func sd(_ xs: [Double]) -> Double {
            let mu = xs.reduce(0, +) / Double(xs.count)
            return (xs.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Double(xs.count)).squareRoot()
        }
        let dt = imp.last!.t.timeIntervalSince(imp.first!.t) / Double(max(1, imp.count - 1))
        let peak = imp.map { $0.magnitude }.max() ?? 0
        return Features(peak: peak,
                        turn: angle(meanVector(pre), meanVector(post)) ?? 0,
                        postSD: sd(post.map { $0.magnitude }),
                        energy: imp.map { abs($0.magnitude - 1) }.reduce(0, +) * dt,
                        preSD: sd(pre.map { $0.magnitude }))
    }

    static func meanVector(_ pts: [AccelPoint]) -> (Double, Double, Double)? {
        guard !pts.isEmpty else { return nil }
        let n = Double(pts.count)
        return (pts.map { $0.x }.reduce(0, +) / n, pts.map { $0.y }.reduce(0, +) / n, pts.map { $0.z }.reduce(0, +) / n)
    }

    static func angle(_ a: (Double, Double, Double)?, _ b: (Double, Double, Double)?) -> Double? {
        guard let a, let b else { return nil }
        let na = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).squareRoot(), nb = (b.0 * b.0 + b.1 * b.1 + b.2 * b.2).squareRoot()
        guard na > 0.2, nb > 0.2 else { return nil }
        let c = max(-1, min(1, (a.0 * b.0 + a.1 * b.1 + a.2 * b.2) / (na * nb)))
        return acos(c) * 180 / .pi
    }

    /// A synthetic fall for the "Simulate a fall" button and tests: standing, a short drop, a hard
    /// impact, then lying still with the device turned about 80 degrees.
    public static func syntheticFall(start: Date, rateHz: Double = 50) -> [AccelPoint] {
        var out: [AccelPoint] = []
        let dt = 1 / rateHz
        var t = 0.0
        func add(_ x: Double, _ y: Double, _ z: Double) { out.append(AccelPoint(t: start.addingTimeInterval(t), x: x, y: y, z: z)); t += dt }
        var seed: UInt64 = 42
        func noise(_ a: Double) -> Double { seed = seed &* 6364136223846793005 &+ 1; return (Double(seed >> 11) / Double(1 << 53) - 0.5) * 2 * a }
        while t < 3.0 { add(0.1 + noise(0.04), -0.2 + noise(0.04), 0.97 + noise(0.04)) }        // standing
        let ffEnd = t + 0.3
        while t < ffEnd { add(noise(0.1), noise(0.1), 0.3 + noise(0.1)) }                       // drop
        let impactEnd = t + 0.12
        while t < impactEnd { add(3.1, 2.8, 3.2) }                                              // impact
        let reboundEnd = t + 0.25
        while t < reboundEnd { add(1.6 + noise(0.3), 0.8 + noise(0.3), 1.2 + noise(0.3)) }      // rebound
        let end = t + 4.5
        while t < end { add(0.98 + noise(0.02), 0.05 + noise(0.02), 0.1 + noise(0.02)) }        // lying, turned
        return out
    }
}
