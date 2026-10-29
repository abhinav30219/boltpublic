import Foundation
import CoreMotion
import BoltCore

/// Streams the iPhone's own accelerometer (via Core Motion) as IMU samples, so fall detection and
/// wave / shake gestures work with no band at all: the phone in a pocket or hand is the sensor.
/// Values are delivered in g and wrapped as `LiveInput.imu`, the same shape the rest of the app uses.
@MainActor
final class PhoneMotionSource {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    /// Delivered on the main actor as batches, like the live band path.
    var onInput: ((LiveInput) -> Void)?

    var rateHz: Double = 30 {
        didSet { manager.accelerometerUpdateInterval = 1 / rateHz }
    }

    var isAvailable: Bool { manager.isAccelerometerAvailable }

    func start() {
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = 1 / rateHz
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let data else { return }
            // Core Motion reports acceleration in g (gravity included on the raw accelerometer).
            let g = IMUScale.standardGravity
            let sample = IMUSample(tMs: Date().timeIntervalSince1970 * 1000,
                                   axMS2: data.acceleration.x * g,
                                   ayMS2: data.acceleration.y * g,
                                   azMS2: data.acceleration.z * g)
            Task { @MainActor [weak self] in self?.onInput?(.imu([sample])) }
        }
    }

    func stop() {
        if manager.isAccelerometerActive { manager.stopAccelerometerUpdates() }
    }
}
