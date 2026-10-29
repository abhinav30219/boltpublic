import Combine
import UIKit
import BoltCore
import Foundation

/// Owns the PoseSolver and everything the renderer and overlays read. `nextPose` is called from
/// SceneKit's render thread, so the solver, the state snapshot and the frame counters sit behind a lock.
@MainActor
final class CompanionDriver: ObservableObject {
    private final class Core: @unchecked Sendable {
        let lock = NSLock()
        var solver: PoseSolver
        var state = CompanionState()
        var appearance = Appearance()
        var twin = RobotTwin()
        var followsTwin = true
        var lastOneShot: Date?
        var lift = 0.0
        var framing = 0.0
        var frames = 0
        var totalFrames = 0
        var reduceMotion = false
        var windowStart = 0.0
        var workMs = 0.0
        init(tuning: Tuning) { solver = PoseSolver(tuning: tuning.companion) }
    }

    private let core: Core
    private var cancellables = Set<AnyCancellable>()
    private var eventSink: AnyCancellable?

    var tuning: Tuning {
        didSet {
            core.lock.lock(); core.solver.tuning = tuning.companion; core.lock.unlock()
            syncReduceMotion()
            objectWillChange.send() // lets the SceneKit view pick up render.* fps changes
        }
    }
    /// System Reduce Motion (observed live).
    @Published private(set) var systemReduceMotion = UIAccessibility.isReduceMotionEnabled {
        didSet { syncReduceMotion() }
    }
    /// System setting OR tuning.render.reduceAnimation.
    var reduceMotion: Bool { systemReduceMotion || tuning.render.reduceAnimation }
    @Published var state: CompanionState { didSet { core.lock.lock(); core.state = state; core.lock.unlock() } }
    /// The robot's body; drives the pose when `followsTwin`. Face, blush and overlays stay with `state`.
    @Published var twin = RobotTwin() { didSet { core.lock.lock(); core.twin = twin; core.lock.unlock() } }
    /// False for the lab, which poses the body by hand from `state`.
    var followsTwin = true { didSet { core.lock.lock(); core.followsTwin = followsTwin; core.lock.unlock() } }
    @Published var appearance = Appearance() { didSet { core.lock.lock(); core.appearance = appearance; core.lock.unlock() } }
    @Published var isGenerating = false
    @Published var isVisible = true
    /// Increments on every celebration; overlays watch it for confetti.
    @Published private(set) var celebrationCount = 0
    @Published var lastFrameMs = 0.0
    @Published var fps = 0.0
    @Published var loadIssue: String?

    init(tuning: Tuning) {
        self.tuning = tuning
        core = Core(tuning: tuning)
        state = core.state
        syncReduceMotion()
        NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.systemReduceMotion = UIAccessibility.isReduceMotionEnabled }
            .store(in: &cancellables)
    }

    private func syncReduceMotion() {
        core.lock.lock(); core.reduceMotion = reduceMotion; core.lock.unlock()
    }

    var targetFPS: Int {
        guard isVisible else { return 0 }
        let r = tuning.render
        let fps = reduceMotion || isGenerating ? r.generatingFPS : r.visibleFPS
        return Int(min(120, max(1, fps.isFinite ? fps : 30)))
    }

    /// Frames rendered since launch (any thread). Debug aid: must stop advancing while paused.
    nonisolated var frameCount: Int {
        core.lock.lock(); defer { core.lock.unlock() }
        return core.totalFrames
    }

    /// Latest body lift in meters (any thread); drives the shadow.
    nonisolated var currentLift: Double {
        core.lock.lock(); defer { core.lock.unlock() }
        return core.lift
    }

    /// How much farther than normal the camera should sit right now (1 = normal): grows during a flip so the
    /// whole body stays in frame, then eases back. Any thread.
    nonisolated var cameraDistanceScale: Double {
        core.lock.lock(); defer { core.lock.unlock() }
        return 1 + max(0, core.solver.tuning.flipCameraPullback) * core.framing
    }

    /// Thread-safe copy of what the render thread needs besides the pose.
    nonisolated var renderSnapshot: (Appearance, CompanionState) {
        core.lock.lock(); defer { core.lock.unlock() }
        return (core.appearance, core.state)
    }

    nonisolated func nextPose(dt: Double) -> Pose {
        core.lock.lock(); defer { core.lock.unlock() }
        var state = core.state
        core.solver.walkForward = true
        core.solver.gaze = nil
        core.solver.idleLife = !core.reduceMotion   // Reduce Motion keeps only breathing
        if core.followsTwin {
            let body = core.twin.body(at: Date())
            state.motion = body.motion
            state.cadence = body.cadence
            core.solver.walkForward = body.forward
            core.solver.gaze = body.gaze.map { PoseGaze(yawDeg: $0.yawDeg, pitchDeg: $0.pitchDeg) }
            if let shot = body.oneShot, shot.startedAt != core.lastOneShot {
                core.lastOneShot = shot.startedAt
                if !core.reduceMotion { core.solver.play(shot.kind == .wave ? .wave : .flip) }
            }
        }
        if core.reduceMotion, state.motion == .walk || state.motion == .trot { state.motion = .idle }
        let pose = core.solver.step(state: state, dt: dt)
        core.lift = pose.bodyLift
        core.framing = pose.framing
        return pose
    }

    /// Plays a wave or flip on the local solver (the lab, where `followsTwin` is false).
    func play(_ shot: PoseSolver.OneShot) {
        core.lock.lock(); defer { core.lock.unlock() }
        if !core.reduceMotion { core.solver.play(shot) }
    }

    /// Triggers an idle fidget now (the lab). Shows only while the body is standing idle.
    func forceIdle(_ kind: PoseSolver.IdleFidget) {
        core.lock.lock(); defer { core.lock.unlock() }
        core.solver.forceIdleFidget(kind)
    }

    func celebrate() {
        // Reduce Motion: no hop, the overlay shows a glow instead.
        if !reduceMotion { core.lock.lock(); core.solver.celebrate(); core.lock.unlock() }
        celebrationCount += 1
        #if DEBUG
        NSLog("[companion] celebrate #%d", celebrationCount)
        #endif
    }

    /// One subscription at a time: attaching again replaces the previous one.
    func attach(events: some Publisher<CompanionEvent, Never>) {
        eventSink = events.receive(on: DispatchQueue.main).sink { [weak self] event in
            if event == .stepMilestone || event == .goalReached { self?.celebrate() }
        }
    }

    /// Called by the renderer once per frame from any thread; publishes fps and frame cost twice a second.
    nonisolated func recordFrame(workMs: Double, now: Double) {
        core.lock.lock()
        core.frames += 1
        core.totalFrames += 1
        core.workMs += workMs
        var report: (fps: Double, ms: Double)?
        if core.windowStart == 0 { core.windowStart = now }
        let span = now - core.windowStart
        if span >= 0.5 {
            report = (Double(core.frames) / span, core.workMs / Double(core.frames))
            core.frames = 0; core.workMs = 0; core.windowStart = now
        }
        core.lock.unlock()
        if let r = report {
            DispatchQueue.main.async { [weak self] in self?.fps = r.fps; self?.lastFrameMs = r.ms }
        }
    }
}

/// Which 3D renderer draws the companion. Stored in `UserDefaults` under `defaultsKey`; SceneKit is the default.
enum CompanionRendererKind: String, CaseIterable, Identifiable {
    case sceneKit, realityKit

    static let defaultsKey = "companionRenderer"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sceneKit: return "SceneKit"
        case .realityKit: return "RealityKit"
        }
    }
}
