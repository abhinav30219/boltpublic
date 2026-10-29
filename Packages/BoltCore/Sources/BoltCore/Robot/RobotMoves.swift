import Foundation

/// How a skill command runs, from the robot's command table.
public enum RobotContract: String, Codable, CaseIterable, Sendable {
    /// Runs once and returns to its posture on its own.
    case once
    /// Takes a step count: `kwkF 3`.
    case steps
    /// Keeps going until told to stop. The robot doesn't stop timed skills on
    /// its own, so the app sends the stop command (`kup`) after `seconds`.
    case timed

    public var label: String {
        switch self {
        case .once: return "Once"
        case .steps: return "Steps"
        case .timed: return "Timed"
        }
    }
}

/// One move the app can ask the robot for, editable on the phone so commands
/// can be tried and changed without a rebuild.
public struct RobotMove: Codable, Equatable, Identifiable, Sendable {
    /// Stable key the app triggers the move by (see `RobotMove.Key`); custom moves get a UUID.
    public var id: String
    public var title: String
    /// Skill text as sent, e.g. `khi`. Arguments can be typed in: `m0 30`.
    public var command: String
    public var contract: RobotContract
    /// Step count for `.steps`.
    public var count: Int
    /// Seconds before the stop command for `.timed`.
    public var seconds: Double

    public init(id: String = UUID().uuidString, title: String, command: String,
                contract: RobotContract = .once, count: Int = 1, seconds: Double = 3) {
        self.id = id; self.title = title; self.command = command
        self.contract = contract; self.count = count; self.seconds = seconds
    }

    /// Keys of the moves the app itself uses. Their moves can be edited but not deleted.
    public enum Key {
        public static let stand = "stand"
        public static let rest = "rest"
        public static let wave = "wave"
        public static let doubleTap = "doubleTap"
        public static let walkForward = "walkForward"
        public static let walkSteps = "walkSteps"
        public static let walkBack = "walkBack"
        public static let all = [stand, rest, wave, doubleTap, walkForward, walkSteps, walkBack]
    }

    public var isBuiltIn: Bool { Key.all.contains(id) }

    /// The text written to the robot: the command, plus the count for `.steps`.
    public var text: String {
        let base = command.trimmingCharacters(in: .whitespaces)
        return contract == .steps ? "\(base) \(max(1, count))" : base
    }

    public var robotCommand: RobotCommand { .text(text) }

    /// Seconds after which the stop command goes out, for `.timed` only.
    public var stopAfter: TimeInterval? { contract == .timed ? max(0.5, seconds) : nil }

    /// Short summary for lists: `kwkF 3`, `kstep1F · 3 s then kup`.
    public func summary(stop: String) -> String {
        if let s = stopAfter { return "\(text) · \(Self.format(s)) s then \(stop)" }
        return text
    }

    static func format(_ s: Double) -> String {
        s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
    }
}

/// The moves the app sends, stored on the phone as JSON.
public struct RobotMoveConfig: Codable, Equatable, Sendable {
    /// Sent after a timed move, and by Stop.
    public var stop: String
    public var moves: [RobotMove]

    public init(stop: String, moves: [RobotMove]) { self.stop = stop; self.moves = moves }

    public var stopCommand: RobotCommand { .text(stop.trimmingCharacters(in: .whitespaces)) }

    public func move(_ id: String) -> RobotMove? { moves.first { $0.id == id } }

    /// Commands confirmed on the demo robot.
    public static let defaults = RobotMoveConfig(stop: "kup", moves: [
        RobotMove(id: RobotMove.Key.stand, title: "Stand", command: "kup"),
        RobotMove(id: RobotMove.Key.rest, title: "Rest", command: "krest"),
        RobotMove(id: RobotMove.Key.wave, title: "Wave hi", command: "khi"),
        RobotMove(id: RobotMove.Key.doubleTap, title: "Double tap (backflip)", command: "kflipRoll"),
        RobotMove(id: RobotMove.Key.walkForward, title: "Walk forward", command: "kstep1F", contract: .timed, seconds: 3),
        RobotMove(id: RobotMove.Key.walkSteps, title: "Walk 3 steps", command: "kwkF", contract: .steps, count: 3),
        RobotMove(id: RobotMove.Key.walkBack, title: "Walk back", command: "kbkF", contract: .steps, count: 2),
    ])

    /// Decodes saved JSON. Built-in moves missing from it (added in a later
    /// version) are put back with their defaults; unreadable data gives the defaults.
    public static func load(_ data: Data?) -> RobotMoveConfig {
        guard let data, var c = try? JSONDecoder().decode(RobotMoveConfig.self, from: data) else { return defaults }
        for d in defaults.moves where c.move(d.id) == nil { c.moves.append(d) }
        return c
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// Every command from the robot's command tables, for picking and trying.
public enum RobotCatalog {
    public struct Entry: Identifiable, Equatable, Sendable {
        public var command: String
        public var function: String
        public var contract: RobotContract
        public var id: String { command }
    }

    public struct Group: Identifiable, Sendable {
        public var title: String
        public var entries: [Entry]
        public var id: String { title }
    }

    /// Rows are `command<TAB>function[<TAB>contract]`; `a / b` lists several commands sharing a row.
    static func parse(_ rows: String, contract fallback: RobotContract = .once) -> [Entry] {
        rows.split(separator: "\n").flatMap { row -> [Entry] in
            let cols = row.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2 else { return [] }
            let contract = cols.count > 2 ? (RobotContract(rawValue: cols[2].lowercased()) ?? fallback) : fallback
            return cols[0].components(separatedBy: " / ").map {
                Entry(command: $0.trimmingCharacters(in: .whitespaces), function: cols[1], contract: contract)
            }
        }
    }

    public static let groups: [Group] = [
        Group(title: "Postures", entries: parse("""
        ksit\tSit
        krest\tLie down / rest
        kup\tNormal standing posture
        kbalance\tStand and balance
        kstr\tStretch
        kbuttUp\tButt up
        d\tRest / standby / sleep / stop
        krc\tRecover / get back up
        krc2\tRecovery variant
        krcL / krcR\tRecover left / right
        """)),
        Group(title: "Gaits", entries: parse("""
        kstep1F\tStep forward (confirmed walk)\ttimed
        kwkF\tWalk forward\tsteps
        kbkF\tWalk backward\tsteps
        ktrF\tTrot / run forward\tsteps
        kcrF\tCrawl forward\tsteps
        kbdF\tBound forward\tsteps
        kdragWkF\tDrag-walk forward\tsteps
        ktiptoeF\tTiptoe forward\tsteps
        kmarchF\tMarch\tsteps
        kpaceF\tPace forward\tsteps
        ktriCatF\tTripod walk forward\tsteps
        kwkL / kwkR\tTurn left / right\ttimed
        kwkB\tAlternative backward walk\ttimed
        kbkL / kbkR\tBack left / right\ttimed
        ktrL / ktrR\tTrot left / right\ttimed
        ktrB\tTrot backward\ttimed
        kcrL / kcrR\tCrawl left / right\ttimed
        kvtL / kvtR\tSpin left / right\ttimed
        kvt2L / kvt2R\tTighter turn left / right\ttimed
        kvt90L / kvt90R\t90° turn left / right\ttimed
        ksideL / ksideR\tSide-step left / right\ttimed
        ktriCatL / ktriCatR\tTripod walk left / right\ttimed
        kcircle2L\tCircle\ttimed
        kslide\tSlide\ttimed
        kbackScoot\tBack scoot\ttimed
        kbbbk\tBackward variant\ttimed
        kgallop\tGallop\ttimed
        kglide\tGlide\tonce
        """)),
        Group(title: "Tricks", entries: parse("""
        khi\tWave / say hi
        khsk\tHandshake
        kfiv\tHigh-five
        knd\tNod
        kwh\tWave / shake head
        kang\tAngry
        kzz\tSleepy
        ksnf\tSniff
        kscrh\tScratch
        kpee\tPee
        kpd / kpd2\tPlay dead / variant
        kpu\tPush-up
        kbx\tBoxing
        kkc\tKick
        kjmp\tJump
        kjumpSlide\tJump slide
        kbf\tBackflip
        kff\tFront flip
        krl\tRoll
        kflipRoll\tFlip roll (confirmed backflip)
        khds\tHandstand
        khighbar\tHigh bar
        T\tReplay the skill just learned
        """)),
        Group(title: "Moves", entries: parse("""
        kqDance\tDance
        kqStep\tFull step
        kqStepHalf\tHalf step
        kqWheel\tWheel
        kqBiped\tBiped
        kqScoot\tScoot
        kqFrontScoot\tFront scoot
        """)),
        Group(title: "Joints and modes", entries: parse("""
        m0 0\tHead / neck angle; + left, − right
        m8 0\tLeft front leg angle; − forward, + back
        m9 0\tRight front leg angle; − forward, + back
        XO\tBluetooth mouse mode
        Xo\tBack to normal robot mode
        """)),
        Group(title: "Eyes", entries: parse("""
        vcr / vcb\tRed / blue
        vco / vcy\tOrange / yellow
        vcg / vcp / vcv\tGreen / pink / purple
        veH\tHappy
        veS\tSad
        veP\tSquint
        vetL\tListening
        velT\tTalking, neutral
        veTH\tTalking, happy
        veTS\tTalking, sad
        veTP\tTalking, squint
        vet\tEnd talking expression
        ved\tClear expression
        """)),
    ]

    public static var all: [Entry] { groups.flatMap(\.entries) }

    public static func entry(_ command: String) -> Entry? { all.first { $0.command == command } }
}
