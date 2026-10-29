import Foundation
import CoreBluetooth
import Combine
import BoltCore

/// The app's Bluetooth link to the Quaddle robot over the Nordic UART service
/// (same as `tools/quaddle_ble.py`). Commands run one at a time, in the order
/// sent; each one listens for the robot's reply lines before the next goes out.
@MainActor
final class RobotLink: NSObject, ObservableObject {
    enum Status: Equatable {
        case poweredOff, unauthorized, idle, scanning, connecting(String), discovering, ready(String), away(String)
        var label: String {
            switch self {
            case .poweredOff: return "Bluetooth is off"
            case .unauthorized: return "Bluetooth permission needed"
            case .idle: return "Not connected"
            case .scanning: return "Looking for the robot…"
            case .connecting(let n): return "Connecting to \(n)…"
            case .discovering: return "Setting up…"
            case .ready(let n): return "Connected · \(n)"
            case .away(let why): return "Away · \(why)"
            }
        }
    }

    struct Found: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var found: [Found] = []
    /// Reply lines from the last command, for the Robot screen.
    @Published private(set) var lastReplies: [String] = []
    /// The command being sent, or nil.
    @Published private(set) var sending: String?
    /// The commands behind each move, editable on the Robot screen and saved on the phone.
    @Published var moves: RobotMoveConfig {
        didSet { UserDefaults.standard.set(moves.encoded(), forKey: Self.movesKey) }
    }

    /// Every command the app sends, as it goes out (or immediately when there is no robot), so the
    /// on-screen twin can mirror it.
    let dispatched = PassthroughSubject<RobotCommand, Never>()

    var onLog: ((TraceEntry.Kind, String, String, Double?) -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?
    private var wantsConnection = false
    /// Connect to the first robot named `RobotUUIDs.defaultName` that the scan finds.
    private var autoConnect = false
    /// Queued commands; `stopAfter` is set for timed moves.
    private var queue: [(command: RobotCommand, stopAfter: TimeInterval?)] = []
    private var current: (command: RobotCommand, replies: RobotReplyCollector)?
    private var replyTimer: Timer?
    /// Pending stop commands for timed moves.
    private var stopTasks: [UUID: Task<Void, Never>] = [:]
    private static let savedKey = "robot.lastPeripheral"
    private static let movesKey = "robot.moves"
    private var sayTestDone = false

    private let uartService = CBUUID(string: RobotUUIDs.uartService)
    private let rxUUID = CBUUID(string: RobotUUIDs.uartRX)
    private let txUUID = CBUUID(string: RobotUUIDs.uartTX)

    override init() {
        moves = RobotMoveConfig.load(UserDefaults.standard.data(forKey: Self.movesKey))
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var savedPeripheralID: UUID? {
        UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:))
    }

    var isReady: Bool { if case .ready = status { return true } else { return false } }

    /// A command is running or waiting.
    var isBusy: Bool { current != nil || !queue.isEmpty }

    /// Scans by name (the robot may not advertise the UART service). With
    /// `autoConnect`, connects as soon as the demo robot shows up.
    func startScan(autoConnect: Bool = false) {
        guard central.state == .poweredOn else { return }
        found = []
        self.autoConnect = autoConnect
        status = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        autoConnect = false
        if status == .scanning { status = .idle }
    }

    func connect(_ id: UUID) {
        guard let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        central.stopScan()
        autoConnect = false
        wantsConnection = true
        peripheral = p
        p.delegate = self
        status = .connecting(p.name ?? "robot")
        central.connect(p, options: nil)
    }

    func disconnect() {
        wantsConnection = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        status = .idle
    }

    func forget() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
    }

    /// Drops commands that are queued but not yet written; the one being written finishes.
    func dropQueued() { queue.removeAll() }

    /// True when `send(command)` would actually be written: connected, and the payload fits the
    /// peripheral's write limit for the write type `pump()` will use. Check this before relying on
    /// the robot for something that matters (a spoken fall line).
    func canDeliver(_ command: RobotCommand) -> Bool {
        guard isReady, let p = peripheral, let rx = rxChar else { return false }
        return command.payload.count <= p.maximumWriteValueLength(for: Self.writeType(for: rx))
    }

    /// Same rule as quaddle_ble.py: write with response when the robot offers it.
    private static func writeType(for rx: CBCharacteristic) -> CBCharacteristicWriteType {
        rx.properties.contains(.write) ? .withResponse : .withoutResponse
    }

    /// Queues `command` behind any command still running. Dropped, with a
    /// trace warning, when the robot isn't connected.
    func send(_ command: RobotCommand) { enqueue(command, stopAfter: nil) }

    private func enqueue(_ command: RobotCommand, stopAfter: TimeInterval?) {
        guard isReady else {
            onLog?(.warning, "Robot: \(command.label) not delivered (no robot)", status.label, nil)
            dispatched.send(command)
            return
        }
        queue.append((command, stopAfter))
        pump()
    }

    /// Runs the move saved under `key` (see `RobotMove.Key`), e.g. `.wave` on a hello.
    func perform(_ key: String) {
        guard let move = moves.move(key) else {
            onLog?(.warning, "Robot: no move \(key)", "", nil)
            return
        }
        perform(move)
    }

    /// Sends the move's command. A timed move is followed by the stop command
    /// its seconds after it is written, since the robot doesn't end timed skills itself.
    func perform(_ move: RobotMove) { enqueue(move.robotCommand, stopAfter: move.stopAfter) }

    private func scheduleStop(after: TimeInterval) {
        let id = UUID()
        stopTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.stopTasks[id] = nil
            self.sendStop(clearQueue: false)
        }
    }

    /// Sends the stop command now, ahead of anything queued: the reply wait
    /// for the running command is cut short. With `clearQueue`, also drops
    /// queued commands and pending timed stops.
    func sendStop(clearQueue: Bool = true) {
        if clearQueue {
            cancelStops()
            queue.removeAll()
        }
        guard isReady else { send(moves.stopCommand); return }
        queue.insert((moves.stopCommand, nil), at: 0)
        if current != nil { finish(failure: nil) } else { pump() }
    }

    func resetMoves() { moves = .defaults }

    private func cancelStops() {
        stopTasks.values.forEach { $0.cancel() }
        stopTasks.removeAll()
    }

    private func pump() {
        guard current == nil, !queue.isEmpty, let p = peripheral, let rx = rxChar else { return }
        let (command, stopAfter) = queue.removeFirst()
        let type = Self.writeType(for: rx)
        let payload = command.payload
        let limit = p.maximumWriteValueLength(for: type)
        guard payload.count <= limit else {
            onLog?(.warning, "Robot: \(command.label) not sent", "\(payload.count) bytes is over the \(limit)-byte write limit", nil)
            pump()
            return
        }
        // A spoken line gets no useful reply, so don't hold the queue (and the alarm repeat) for the full 8 s.
        let listen: TimeInterval = command.label.hasPrefix(">> say ") ? 2 : 8
        current = (command, RobotReplyCollector(sentAt: Date(), listenSeconds: listen))
        sending = command.label
        dispatched.send(command)
        p.writeValue(payload, for: rx, type: type)
        if let stopAfter { scheduleStop(after: stopAfter) }
        replyTimer?.invalidate()
        replyTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReply() }
        }
    }

    private func checkReply() {
        guard let c = current, c.replies.isDone(at: Date()) else { return }
        finish(failure: nil)
    }

    /// Ends the current command, logs it and sends the next one.
    private func finish(failure: String?) {
        replyTimer?.invalidate()
        replyTimer = nil
        guard let c = current else { return }
        current = nil
        sending = nil
        let lines = c.replies.allLines
        lastReplies = lines
        let ms = Date().timeIntervalSince(c.replies.sentAt) * 1000
        if let failure {
            onLog?(.warning, "Robot: \(c.command.label) failed", failure, nil)
        } else if c.replies.gotReply {
            onLog?(.robot, "Robot: \(c.command.label)", lines.joined(separator: " | "), ms)
        } else {
            onLog?(.warning, "Robot: \(c.command.label) sent, no reply", "Execution unconfirmed", ms)
        }
        pump()
    }

    private func dropConnection(_ why: String) {
        rxChar = nil; txChar = nil
        queue.removeAll()
        cancelStops()
        if current != nil { finish(failure: why) }
    }
}

extension RobotLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if status == .poweredOff || status == .unauthorized { status = .idle }
                if let id = savedPeripheralID { connect(id) }
            case .poweredOff:
                dropConnection("Bluetooth turned off")
                status = .poweredOff
            case .unauthorized: status = .unauthorized
            case .unsupported: status = .away("no Bluetooth on this device")
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        MainActor.assumeIsolated {
            guard RobotUUIDs.isRobotName(name) else { return }
            peripherals[peripheral.identifier] = peripheral
            let item = Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let i = found.firstIndex(where: { $0.id == item.id }) { found[i] = item } else { found.append(item) }
            found.sort { $0.rssi > $1.rssi }
            if autoConnect, name == RobotUUIDs.defaultName { connect(peripheral.identifier) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedKey)
            status = .discovering
            peripheral.discoverServices([uartService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { status = .away(error?.localizedDescription ?? "couldn't connect") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            dropConnection("Robot disconnected")
            if wantsConnection {
                status = .away(error?.localizedDescription ?? "reconnecting")
                onLog?(.warning, "Robot disconnected", "Reconnecting when it's back", nil)
                central.connect(peripheral, options: nil)   // iOS keeps this pending until the robot is back
            } else {
                status = .idle
            }
        }
    }
}

extension RobotLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = peripheral.services?.first(where: { $0.uuid == uartService }) else {
                status = .away("no UART service")
                return
            }
            peripheral.discoverCharacteristics([rxUUID, txUUID], for: s)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.uuid == rxUUID, !c.properties.isDisjoint(with: [.write, .writeWithoutResponse]) { rxChar = c }
                if c.uuid == txUUID, !c.properties.isDisjoint(with: [.notify, .indicate]) { txChar = c }
            }
            guard rxChar != nil, let tx = txChar else {
                status = .away("UART characteristics not usable")
                return
            }
            peripheral.setNotifyValue(true, for: tx)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == txUUID else { return }
            if let error {
                status = .away("notify failed: \(error.localizedDescription)")
                return
            }
            let name = peripheral.name ?? RobotUUIDs.defaultName
            status = .ready(name)
            onLog?(.robot, "Robot connected", name, nil)
            pump()
            #if DEBUG
            // -robotSayTest: three speech variants, 6 s apart, to hear which one the robot voices.
            if ProcessInfo.processInfo.arguments.contains("-robotSayTest"), !sayTestDone {
                sayTestDone = true
                Task { @MainActor [weak self] in
                    for line in [#">> say "Hello Abhinav, I am Bolt""#, #"> say "This is the second way""#, ">> Hello, how are you?"] {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self?.onLog?(.robot, "Robot say test", line, nil)
                        self?.send(.text(line))
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                }
            }
            #endif
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { finish(failure: "write failed: \(error.localizedDescription)") }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == txUUID, let value = characteristic.value else { return }
        MainActor.assumeIsolated {
            if current != nil {
                current?.replies.add(value, at: Date())
            } else {
                let text = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { onLog?(.robot, "Robot said", text, nil) }
            }
        }
    }
}
