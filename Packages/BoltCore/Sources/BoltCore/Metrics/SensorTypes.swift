import Foundation

// Generic sensor data containers. These are plain value types that describe a
// heart-rate reading, an accelerometer sample, a temperature sample and a wear
// state. They are not tied to any particular band or wire format: a standard
// Bluetooth Heart Rate strap, the iPhone's own motion sensors, a recorded
// session or the synthetic demo all produce the same shapes.

// `LiveInput` (the tagged union of these samples) is declared in LiveTypes.swift.

/// A heart-rate / HRV / SpO2 reading. Most fields are optional because a given
/// source may only provide some of them (a plain HR strap provides `hrBpm`).
public struct CardiacReading: Equatable, Sendable {
    public var seq: UInt16
    public var hrBpm: Double?
    public var ibiMs: Double?
    public var rmssdMs: Double?
    public var spo2Pct: Double?
    /// 0..1000 fraction of the window with a valid signal (1000 = fully valid).
    public var validPermille: Int
    /// Source timestamp in unix milliseconds, when known.
    public var tMs: Double?

    public init(
        seq: UInt16 = 0,
        hrBpm: Double? = nil,
        ibiMs: Double? = nil,
        rmssdMs: Double? = nil,
        spo2Pct: Double? = nil,
        validPermille: Int = 1000,
        tMs: Double? = nil
    ) {
        self.seq = seq
        self.hrBpm = hrBpm
        self.ibiMs = ibiMs
        self.rmssdMs = rmssdMs
        self.spo2Pct = spo2Pct
        self.validPermille = validPermille
        self.tMs = tMs
    }
}

/// One accelerometer sample in m/s^2 (and g via `IMUScale`).
public struct IMUSample: Equatable, Sendable {
    public var tMs: Double
    public var axMS2: Double
    public var ayMS2: Double
    public var azMS2: Double

    public init(tMs: Double, axMS2: Double, ayMS2: Double, azMS2: Double) {
        self.tMs = tMs
        self.axMS2 = axMS2
        self.ayMS2 = ayMS2
        self.azMS2 = azMS2
    }
}

public enum IMUScale {
    public static let standardGravity = 9.80665
}

public enum TempSensor: String, Sendable { case a, b }

/// A skin / ambient temperature sample in celsius.
public struct TemperatureSample: Equatable, Sendable {
    public var tMs: Double
    public var celsius: Double
    public var sensor: TempSensor

    public init(tMs: Double, celsius: Double, sensor: TempSensor = .a) {
        self.tMs = tMs
        self.celsius = celsius
        self.sensor = sensor
    }
}

/// Whether the device is being worn / in use.
public enum WearState: String, Sendable {
    case on, off, unknown
}

/// A wear-state sample. `isWorn` is nil when the state says nothing either way.
public struct WearStatusSample: Equatable, Sendable {
    public var tMs: Double
    public var state: WearState

    public var isWorn: Bool? {
        switch state {
        case .on: return true
        case .off: return false
        case .unknown: return nil
        }
    }

    public init(tMs: Double, state: WearState) {
        self.tMs = tMs
        self.state = state
    }
}

/// Everything decoded from one source update.
public struct TelemetryBatch: Sendable {
    public var imu: [IMUSample] = []
    public var temperatures: [TemperatureSample] = []
    public var wear: [WearStatusSample] = []
    public var cardiac: [CardiacReading] = []
    public init() {}

    public var isEmpty: Bool {
        imu.isEmpty && temperatures.isEmpty && wear.isEmpty && cardiac.isEmpty
    }
}
