import Foundation
import CoreBluetooth
import BoltCore

extension HeartRateBand: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: if status == .poweredOff { status = .idle }
            case .poweredOff: status = .poweredOff
            case .unauthorized: status = .unauthorized
            default: status = .idle
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
            guard !name.isEmpty else { return }   // unnamed devices are almost never HR straps
            peripherals[peripheral.identifier] = peripheral
            let item = Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let i = found.firstIndex(where: { $0.id == item.id }) { found[i] = item }
            else { found.append(item) }
            found.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connectedName = peripheral.name
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedKey)
            status = .discovering
            onLog?("Connected", Self.displayName(peripheral.name ?? ""))
            peripheral.discoverServices([heartRateService, batteryService, thermometerService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { status = .disconnected(error?.localizedDescription) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            onInput?(.wear(WearStatusSample(tMs: Date().timeIntervalSince1970 * 1000, state: .off)))
            status = .disconnected(error?.localizedDescription)
            if wantsConnection { central.connect(peripheral, options: nil) }   // auto-retry
        }
    }
}

extension HeartRateBand: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in peripheral.services ?? [] {
                switch s.uuid {
                case heartRateService: peripheral.discoverCharacteristics([heartRateMeasurement], for: s)
                case batteryService: peripheral.discoverCharacteristics([batteryLevel], for: s)
                case thermometerService: peripheral.discoverCharacteristics([temperatureMeasurement], for: s)
                default: break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                switch c.uuid {
                case heartRateMeasurement:
                    peripheral.setNotifyValue(true, for: c)
                    onInput?(.wear(WearStatusSample(tMs: Date().timeIntervalSince1970 * 1000, state: .on)))
                case temperatureMeasurement:
                    peripheral.setNotifyValue(true, for: c)
                case batteryLevel:
                    peripheral.readValue(for: c)
                default: break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        MainActor.assumeIsolated {
            guard let value else { return }
            switch characteristic.uuid {
            case heartRateMeasurement:
                if let hr = Self.parseHeartRate(value) {
                    if status != .streaming { status = .streaming }
                    onInput?(.cardiac(CardiacReading(hrBpm: Double(hr), validPermille: 1000,
                                                     tMs: Date().timeIntervalSince1970 * 1000)))
                }
            case temperatureMeasurement:
                if let c = Self.parseTemperature(value) {
                    onInput?(.temperature(TemperatureSample(tMs: Date().timeIntervalSince1970 * 1000, celsius: c)))
                }
            case batteryLevel:
                battery = value.first.map { Int($0) }
            default: break
            }
        }
    }
}
