import Foundation

/// One recorded sample as a portable, source-agnostic JSON value. Recordings store already-decoded
/// readings (heart rate, motion, temperature, wear), so replay never depends on any band's wire format.
public struct RecordedSample: Codable, Sendable, Equatable {
    public var t: Double            // seconds since recording start
    public var kind: Kind
    public enum Kind: String, Codable, Sendable { case cardiac, imu, temperature, wear }

    // cardiac
    public var hr: Double?
    public var rmssd: Double?
    public var spo2: Double?
    public var validPermille: Int?
    // imu (one sample; chunks are flattened on record, re-batched on load)
    public var ax: Double?
    public var ay: Double?
    public var az: Double?
    // temperature
    public var celsius: Double?
    // wear
    public var worn: Bool?

    public init(t: Double, kind: Kind) { self.t = t; self.kind = kind }
}

/// Records decoded samples to a JSON-lines file.
public final class SessionRecorder {
    public private(set) var items: [RecordedSample] = []
    private var start: Date?
    public init() {}
    public var isEmpty: Bool { items.isEmpty }
    public var duration: Double { items.last?.t ?? 0 }

    public func record(_ input: LiveInput, at now: Date = Date()) {
        if start == nil { start = now }
        let t = now.timeIntervalSince(start!)
        switch input {
        case .cardiac(let r):
            var s = RecordedSample(t: t, kind: .cardiac)
            s.hr = r.hrBpm; s.rmssd = r.rmssdMs; s.spo2 = r.spo2Pct; s.validPermille = r.validPermille
            items.append(s)
        case .imu(let samples):
            for sample in samples {
                var s = RecordedSample(t: sample.tMs / 1000, kind: .imu)
                s.ax = sample.axMS2; s.ay = sample.ayMS2; s.az = sample.azMS2
                items.append(s)
            }
        case .temperature(let temp):
            var s = RecordedSample(t: t, kind: .temperature)
            s.celsius = temp.celsius
            items.append(s)
        case .wear(let w):
            var s = RecordedSample(t: t, kind: .wear)
            s.worn = w.isWorn
            items.append(s)
        }
    }

    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        var out = Data()
        for i in items { out.append(try enc.encode(i)); out.append(0x0A) }
        try out.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> [RecordedSample] {
        let dec = JSONDecoder()
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n").map { try dec.decode(RecordedSample.self, from: Data($0.utf8)) }
    }
}

/// Turns recorded samples back into live inputs. Consecutive IMU samples are re-batched so the
/// store sees them the same way the live path delivers motion.
public final class NotificationDecoder {
    public private(set) var warnings: [String] = []
    public init() {}
    public func reset() { warnings = [] }

    public func decode(_ s: RecordedSample) -> [LiveInput] {
        switch s.kind {
        case .cardiac:
            return [.cardiac(CardiacReading(hrBpm: s.hr, rmssdMs: s.rmssd, spo2Pct: s.spo2,
                                            validPermille: s.validPermille ?? 1000, tMs: s.t * 1000))]
        case .imu:
            return [.imu([IMUSample(tMs: s.t * 1000, axMS2: s.ax ?? 0, ayMS2: s.ay ?? 0, azMS2: s.az ?? 0)])]
        case .temperature:
            return [.temperature(TemperatureSample(tMs: s.t * 1000, celsius: s.celsius ?? 0))]
        case .wear:
            return [.wear(WearStatusSample(tMs: s.t * 1000, state: (s.worn ?? false) ? .on : .off))]
        }
    }
}

/// A deterministic, clearly synthetic 6-minute session for building and testing without a band:
/// rest, 60 s of jogging in place, recovery, then a slow wrist-temperature drop.
public enum SyntheticSession {
    public struct Item: Sendable { public var t: Double; public var input: LiveInput }

    struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    public static let restEnd = 150.0, effortEnd = 210.0, total = 360.0

    public static func make(seed: UInt64 = 7) -> [Item] {
        var rng = LCG(s: seed)
        func noise(_ a: Double) -> Double { (rng.next() - 0.5) * 2 * a }
        var items: [Item] = []
        items.append(Item(t: 0, input: .wear(WearStatusSample(tMs: 0, state: .on))))
        var hr = 67.0
        var seq: UInt16 = 1
        // 1 Hz cardiac
        for s in 0..<Int(total) {
            let t = Double(s)
            let target: Double
            if t < restEnd { target = 67 } else if t < effortEnd { target = 122 } else { target = 69 }
            let tau = t < effortEnd && t >= restEnd ? 9.0 : 22.0
            hr += (target - hr) / tau + noise(0.8)
            let rmssd = max(12, 58 - (hr - 67) * 0.75 + noise(4))
            let spo2 = 97.6 + noise(0.6)
            let r = CardiacReading(seq: seq, hrBpm: hr.rounded(), ibiMs: (60000 / hr).rounded(),
                                   rmssdMs: rmssd.rounded(), spo2Pct: (spo2 * 100).rounded() / 100,
                                   validPermille: 900, tMs: t * 1000)
            seq &+= 1
            items.append(Item(t: t, input: .cardiac(r)))
            if s % 5 == 0 {
                let temp = t < 230 ? 33.4 + noise(0.04) : 33.4 - min(0.8, (t - 230) / 160 * 0.8) + noise(0.04)
                items.append(Item(t: t, input: .temperature(TemperatureSample(tMs: t * 1000, celsius: temp, sensor: .a))))
            }
        }
        // 30 Hz accel in chunks of 3 samples (m/s^2), gravity mostly on z
        let g = IMUScale.standardGravity
        var k = 0
        while Double(k) / 30 < total {
            var chunk: [IMUSample] = []
            for _ in 0..<3 {
                let t = Double(k) / 30
                var ax = 0.05 * g + noise(0.01 * g), ay = 0.1 * g + noise(0.01 * g), az = 0.99 * g + noise(0.01 * g)
                if t >= restEnd && t < effortEnd {
                    // Cadence, a second harmonic and sensor noise: a pure sine reads as "stationary" to the
                    // activity model (checked offline: p=0.87), this reads as running (p about 0.8).
                    let ph = 2 * Double.pi * 2.6 * t
                    ax += 0.9 * g * sin(ph) + 0.4 * g * sin(2 * ph + 0.3) + noise(0.17 * g)
                    ay += 0.5 * g * sin(ph + 1) + 0.3 * g * sin(2 * ph + 1.3) + noise(0.17 * g)
                    az += 1.1 * g * cos(ph) + 0.5 * g * abs(sin(ph)) + noise(0.17 * g)
                } else if t >= effortEnd && t < effortEnd + 20 {
                    ax += 0.08 * g * sin(2 * Double.pi * 0.6 * t)
                }
                chunk.append(IMUSample(tMs: t * 1000, axMS2: ax, ayMS2: ay, azMS2: az))
                k += 1
            }
            items.append(Item(t: chunk.last!.tMs / 1000, input: .imu(chunk)))
        }
        return items.sorted { $0.t < $1.t }
    }
}

/// A deterministic 2-minute session for the stage: walking, then a fall at 60 s (free-fall, impact),
/// then lying still (detected by `Safety/FallDetector`). Same item shape and IMU batching as `SyntheticSession`.
public enum FallDemoSession {
    public static let fallAt = 60.0, total = 120.0
    private static let freeFallSeconds = 0.25, impactSeconds = 0.1

    public static func make(seed: UInt64 = 11) -> [SyntheticSession.Item] {
        var rng = SyntheticSession.LCG(s: seed)
        func noise(_ a: Double) -> Double { (rng.next() - 0.5) * 2 * a }
        var items: [SyntheticSession.Item] = []
        items.append(.init(t: 0, input: .wear(WearStatusSample(tMs: 0, state: .on))))
        var hr = 72.0
        var seq: UInt16 = 1
        // 1 Hz cardiac
        for s in 0..<Int(total) {
            let t = Double(s)
            let target = t < fallAt ? 72.0 : 95.0
            hr += (target - hr) / 6 + noise(0.6)
            let rmssd = max(12, 45 - (hr - 72) * 0.6 + noise(3))
            let r = CardiacReading(seq: seq, hrBpm: hr.rounded(), ibiMs: (60000 / hr).rounded(),
                                   rmssdMs: rmssd.rounded(), spo2Pct: 97.5,
                                   validPermille: 900, tMs: t * 1000)
            seq &+= 1
            items.append(.init(t: t, input: .cardiac(r)))
        }
        // 30 Hz accel in chunks of 3 samples (m/s^2)
        let g = IMUScale.standardGravity
        var k = 0
        while Double(k) / 30 < total {
            var chunk: [IMUSample] = []
            for _ in 0..<3 {
                let t = Double(k) / 30
                var ax = 0.0, ay = 0.0, az = 0.0
                if t < fallAt {
                    az = 1 + 0.35 * sin(2 * Double.pi * 1.8 * t) + noise(0.02)
                    ax = noise(0.02); ay = noise(0.02)
                } else if t < fallAt + freeFallSeconds {
                    az = 0.2
                } else if t < fallAt + freeFallSeconds + impactSeconds {
                    // A hard hit near the band's per-axis ceiling, enough for the fitted fall model.
                    ax = 2.6; ay = 1.5; az = 3.2
                } else {
                    ax = 1 + noise(0.02); ay = noise(0.02); az = noise(0.02)
                }
                chunk.append(IMUSample(tMs: t * 1000, axMS2: ax * g, ayMS2: ay * g, azMS2: az * g))
                k += 1
            }
            items.append(.init(t: chunk.last!.tMs / 1000, input: .imu(chunk)))
        }
        return items.sorted { $0.t < $1.t }
    }
}
