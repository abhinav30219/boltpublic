import Foundation
import Combine
import CoreBluetooth
import BoltCore

/// Connects to any standard Bluetooth heart-rate band, strap or watch using the
/// Bluetooth SIG Heart Rate Service (0x180D / measurement 0x2A37), with optional
/// Battery (0x180F / 0x2A19) and Health Thermometer (0x1809 / 0x2A1C). No private
/// services and no vendor activation handshake: anything that advertises the
/// public Heart Rate Service works.
@MainActor
final class HeartRateBand: NSObject, ObservableObject {
    enum Status: Equatable {
        case poweredOff, unauthorized, idle, scanning, connecting(String), discovering, streaming, disconnected(String?)
        var label: String {
            switch self {
            case .poweredOff: return "Bluetooth is off"
            case .unauthorized: return "Bluetooth permission needed"
            case .idle: return "Not connected"
            case .scanning: return "Looking for a heart-rate band…"
            case .connecting(let n): return "Connecting to \(n)…"
            case .discovering: return "Starting the stream…"
            case .streaming: return "Live"
            case .disconnected(let why): return why.map { "Disconnected: \($0)" } ?? "Disconnected"
            }
        }
    }

    struct Found: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    @Published var status: Status = .idle
    @Published var found: [Found] = []
    @Published var connectedName: String?
    @Published var battery: Int?

    /// Decoded samples (heart rate, temperature, wear) for the store and the recorder.
    var onInput: ((LiveInput) -> Void)?
    /// Connection steps and recoveries, for the trace.
    var onLog: ((String, String) -> Void)?

    var central: CBCentralManager!
    var peripherals: [UUID: CBPeripheral] = [:]
    var peripheral: CBPeripheral?
    var wantsConnection = false
    static let savedKey = "band.lastPeripheral"

    let heartRateService = CBUUID(string: "180D")
    let heartRateMeasurement = CBUUID(string: "2A37")
    let batteryService = CBUUID(string: "180F")
    let batteryLevel = CBUUID(string: "2A19")
    let thermometerService = CBUUID(string: "1809")
    let temperatureMeasurement = CBUUID(string: "2A1C")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var savedPeripheralID: UUID? {
        UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init)
    }

    static func displayName(_ name: String) -> String {
        name.isEmpty ? "Heart-rate band" : name
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        found = []
        status = .scanning
        // Scan broadly so straps that don't advertise the HR service UUID still show up;
        // the service is confirmed after connecting.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        if status == .scanning { status = .idle }
    }

    func connect(_ id: UUID) {
        guard let p = peripherals[id] else { return }
        wantsConnection = true
        central.stopScan()
        peripheral = p
        p.delegate = self
        status = .connecting(Self.displayName(p.name ?? ""))
        central.connect(p, options: nil)
    }

    func reconnectSaved() {
        guard let id = savedPeripheralID else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripherals[id] = known
            connect(id)
        } else {
            startScan()
        }
    }

    /// Reconnect to the saved band if there is one; used on launch for a returning wearer.
    func ensureConnected() {
        if peripheral == nil, savedPeripheralID != nil { reconnectSaved() }
    }

    func disconnect() {
        wantsConnection = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        status = .idle
    }

    /// Disconnect and forget the saved band (used by "reset everything").
    func forget() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        found = []
        connectedName = nil
        battery = nil
    }

    /// Heart Rate Measurement (0x2A37): flags byte; bit 0 = 16-bit value if set, else 8-bit.
    static func parseHeartRate(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        if flags & 0x01 == 0 {
            return bytes.count >= 2 ? Int(bytes[1]) : nil
        } else {
            return bytes.count >= 3 ? Int(bytes[1]) | (Int(bytes[2]) << 8) : nil
        }
    }

    /// Temperature Measurement (0x2A1C): flags byte then an IEEE-11073 32-bit float; bit 0 selects °F.
    static func parseTemperature(_ data: Data) -> Double? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return nil }
        let mantissa = Int32(bytes[1]) | (Int32(bytes[2]) << 8) | (Int32(bytes[3]) << 16)
        let exponent = Int8(bitPattern: bytes[4])
        var value = Double(mantissa) * pow(10, Double(exponent))
        if bytes[0] & 0x01 != 0 { value = (value - 32) * 5 / 9 }   // Fahrenheit to Celsius
        return (20...45).contains(value) ? value : nil
    }
}
