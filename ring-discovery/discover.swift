import Foundation
import CoreBluetooth

class ConnectionTroubleshooter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var targetPeripheral: CBPeripheral?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[STATE] Bluetooth is ON. Scanning...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        case .unauthorized:
            print("[ERROR] Bluetooth UNAUTHORIZED. Please check System Settings > Privacy > Bluetooth.")
        case .poweredOff:
            print("[ERROR] Bluetooth is OFF.")
        default:
            print("[STATE] Bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        if name.contains("TK5") || name.contains("ring") {
            print("[FOUND] \(name) [\(peripheral.identifier)] RSSI: \(RSSI)")
            print("[ACTION] Stopping scan and attempting connection...")
            self.targetPeripheral = peripheral
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[SUCCESS] Connected to \(peripheral.name ?? "device").")
        peripheral.delegate = self
        print("[ACTION] Discovering services...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[ERROR] Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[DISCONNECT] Peripheral disconnected. Error: \(error?.localizedDescription ?? "None")")
        print("[ACTION] Retrying connection in 2 seconds...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.centralManager.connect(peripheral, options: nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[ERROR] Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            print("[WARN] No services found.")
            return
        }
        print("[INFO] Found \(services.count) services.")
        for service in services {
            print("  - Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        print("[INFO] Found \(chars.count) characteristics for \(service.uuid)")
        for char in chars {
            print("    * Char: \(char.uuid) Props: \(char.properties)")
            if char.properties.contains(.notify) {
                print("      [ACTION] Subscribing to \(char.uuid)")
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[ERROR] Value update failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        if let data = characteristic.value {
            print("[DATA] \(characteristic.uuid): \(data.map{String(format:"%02x",$0)}.joined(separator:" "))")
        }
    }
}

let troubleshooter = ConnectionTroubleshooter()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 120))
