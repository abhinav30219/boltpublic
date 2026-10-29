import Foundation

/// A body command the Quaddle robot understands, reduced to what the 3D twin can show.
public enum RobotMotionCommand: Equatable, Sendable {
    case stand, rest
    case walk(forward: Bool, cycles: Int)
    /// A timed move: walks until the next command (the link's stop command), capped at `maxSeconds`.
    case walkUntilStop(forward: Bool, maxSeconds: Double)
    case wave, flip
    case gaze(x: Int8, y: Int8)

    /// nil for commands with no visible body effect (joints, Wi-Fi query, other text).
    public init?(_ command: RobotCommand) {
        switch command {
        case .text(let raw):
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let head = parts.first else { return nil }
            switch head {
            case "kup" where parts.count == 1: self = .stand
            case "krest" where parts.count == 1: self = .rest
            case "kwkF", "kwkB", "kbkF":
                let n = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                self = .walk(forward: head == "kwkF", cycles: max(1, n))
            default: return nil
            }
        case .binary(let b):
            guard b.count == 5, b[0] == 0x4A, b[1] == 0x72, b[4] == 0x7E else { return nil }
            self = .gaze(x: Int8(bitPattern: b[2]), y: Int8(bitPattern: b[3]))
        }
    }

    /// Maps a dispatched command to a body motion using the live move config, so edited move
    /// text keeps working. Unknown commands fall back to the literal parse.
    public static func resolve(_ command: RobotCommand, moves: RobotMoveConfig) -> RobotMotionCommand? {
        guard case .text(let raw) = command else { return RobotMotionCommand(command) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == moves.stop.trimmingCharacters(in: .whitespacesAndNewlines) { return .stand }
        guard let move = moves.moves.first(where: { $0.text == text }) else { return RobotMotionCommand(command) }
        func walk(_ forward: Bool) -> RobotMotionCommand {
            if move.contract == .timed { return .walkUntilStop(forward: forward, maxSeconds: max(0.5, move.seconds)) }
            return .walk(forward: forward, cycles: move.contract == .steps ? max(1, move.count) : 1)
        }
        switch move.id {
        case RobotMove.Key.stand: return .stand
        case RobotMove.Key.rest: return .rest
        case RobotMove.Key.walkForward, RobotMove.Key.walkSteps: return walk(true)
        case RobotMove.Key.walkBack: return walk(false)
        case RobotMove.Key.wave: return .wave
        case RobotMove.Key.doubleTap: return .flip
        default:
            guard let m = RobotMotionCommand(command) else { return nil }
            if case .walk(let forward, _) = m, move.contract == .timed { return walk(forward) }
            return m
        }
    }
}

/// What the physical robot's body is doing, from the commands sent to it. Pure value; the
/// clock comes in through `at:`.
public struct RobotTwin: Equatable, Sendable {
    public struct Gaze: Equatable, Sendable {
        public var yawDeg: Double, pitchDeg: Double
        public init(yawDeg: Double, pitchDeg: Double) { self.yawDeg = yawDeg; self.pitchDeg = pitchDeg }
    }

    public struct OneShot: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case wave, flip }
        public var kind: Kind
        public var startedAt: Date
        public init(kind: Kind, startedAt: Date) { self.kind = kind; self.startedAt = startedAt }
    }

    public struct TwinBody: Equatable, Sendable {
        /// `.idle`, `.walk` or `.sleep` (the rest pose).
        public var motion: CompanionMotion = .idle
        public var forward = true
        public var cadence = 0.0
        public var gaze: Gaze?
        /// A wave or flip in progress (layered over the base motion by the pose solver).
        public var oneShot: OneShot?
        public init() {}
    }

    private enum Base: Equatable, Sendable {
        case idle, rest
        case walk(forward: Bool, start: Date, duration: Double, cadence: Double)
    }

    private var base: Base = .idle
    private var gaze: Gaze?
    private var oneShot: OneShot?
    private var oneShotSeconds = 0.0

    public init() {}

    public mutating func apply(_ cmd: RobotMotionCommand, at: Date, tuning: CompanionTuning) {
        switch cmd {
        case .stand: base = .idle; gaze = nil; oneShot = nil
        case .rest: base = .rest; gaze = nil; oneShot = nil
        case .walkUntilStop(let forward, let maxSeconds):
            oneShot = nil
            base = .walk(forward: forward, start: at, duration: max(0.5, maxSeconds), cadence: tuning.robotWalkCadence)
        case .wave:
            base = .idle; oneShot = OneShot(kind: .wave, startedAt: at); oneShotSeconds = tuning.robotWaveSeconds
        case .flip:
            base = .idle; oneShot = OneShot(kind: .flip, startedAt: at); oneShotSeconds = tuning.robotFlipSeconds
        case .walk(let forward, let cycles):
            oneShot = nil
            base = .walk(forward: forward, start: at, duration: Double(max(1, cycles)) * tuning.robotWalkCycleSeconds,
                         cadence: tuning.robotWalkCadence)
        case .gaze(let x, let y):
            gaze = Gaze(yawDeg: Double(x) / 127 * tuning.robotGazeMaxYawDeg,
                        pitchDeg: Double(y) / 127 * tuning.robotGazeMaxPitchDeg)
        }
    }

    public func body(at now: Date) -> TwinBody {
        var b = TwinBody()
        b.gaze = gaze
        if let o = oneShot, now.timeIntervalSince(o.startedAt) < oneShotSeconds { b.oneShot = o }
        switch base {
        case .idle: break
        case .rest: b.motion = .sleep
        case .walk(let forward, let start, let duration, let cadence):
            if now.timeIntervalSince(start) < duration {
                b.motion = .walk; b.forward = forward; b.cadence = cadence
            }
        }
        return b
    }
}
