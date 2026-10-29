import Foundation

/// Drag-to-turn state for the companion's camera. The camera orbits the robot's centre (yaw about world Y),
/// so the robot and its ground disc turn together. Main writes (gesture); the render thread (SceneKit) or main
/// (RealityKit) calls `advance(dt:)` every frame. All state is behind one lock.
final class CompanionOrbit: ObservableObject, @unchecked Sendable {
    static let degreesPerPoint = 0.5
    static let springOmega = 8.0 // critically damped; settles (<1%) in about 0.6 s
    static let driftFadeOut = 0.15, driftFadeIn = 1.5

    struct Output { var yaw: Double; var driftWeight: Double }

    private enum Phase { case idle, dragging, waiting, returning }

    private let lock = NSLock()
    private var phase = Phase.idle
    private var yaw = 0.0, velocity = 0.0
    private var waitLeft = 0.0
    private var dragBaseYaw = 0.0
    private var driftWeight = 1.0
    private var returnDelay = 3.0
    private var reduceMotion = false

    /// Camera yaw in radians (not wrapped). Safe from any thread.
    var yawRadians: Double { lock.lock(); defer { lock.unlock() }; return yaw }

    func configure(returnDelay: Double, reduceMotion: Bool) {
        lock.lock(); self.returnDelay = max(0, returnDelay); self.reduceMotion = reduceMotion; lock.unlock()
    }

    /// Touch down on a rotating drag: cancels any wait or return and continues from the current angle.
    func beginDrag() {
        lock.lock(); phase = .dragging; velocity = 0; dragBaseYaw = yaw; lock.unlock()
    }

    /// `translationX` is points since `beginDrag`. Dragging right turns the robot's front to the right.
    func drag(translationX: Double) {
        lock.lock()
        if phase == .dragging { yaw = dragBaseYaw - translationX * Self.degreesPerPoint * .pi / 180 }
        lock.unlock()
    }

    func endDrag() {
        lock.lock()
        if phase == .dragging { phase = .waiting; waitLeft = returnDelay }
        lock.unlock()
    }

    /// Debug hook: set the robot's turn once and start the release wait, as if the finger had just lifted.
    func debugRelease(robotDegrees: Double) {
        lock.lock(); yaw = -robotDegrees * .pi / 180; velocity = 0; phase = .waiting; waitLeft = returnDelay; lock.unlock()
    }

    func advance(dt: Double) -> Output {
        lock.lock(); defer { lock.unlock() }
        switch phase {
        case .idle, .dragging: break
        case .waiting:
            waitLeft -= dt
            if waitLeft <= 0 {
                // Return the short way round.
                yaw = yaw.remainder(dividingBy: 2 * .pi)
                if reduceMotion { yaw = 0; phase = .idle } else { phase = .returning }
            }
        case .returning:
            // Exact critically damped step: x(t) = (x0 + (v0 + w x0) t) e^{-wt}.
            let w = Self.springOmega, e = exp(-w * dt)
            let x0 = yaw, v0 = velocity
            yaw = (x0 + (v0 + w * x0) * dt) * e
            velocity = (v0 - w * (v0 + w * x0) * dt) * e
            if abs(yaw) < 1e-3, abs(velocity) < 1e-2 { yaw = 0; velocity = 0; phase = .idle }
        }
        if phase == .idle { driftWeight = min(1, driftWeight + dt / Self.driftFadeIn) }
        else { driftWeight = max(0, driftWeight - dt / Self.driftFadeOut) }
        return Output(yaw: yaw, driftWeight: driftWeight)
    }
}
