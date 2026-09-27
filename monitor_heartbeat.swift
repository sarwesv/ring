import Foundation
import CoreBluetooth
import CommonCrypto

class DeepLockMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var ring: CBPeripheral?
    var keepAliveTimer: Timer?
    let zeroKey = Data(repeating: 0x00, count: 16)
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("--- Ring Deep-Lock HR Monitor Initialized ---")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("[SCAN] Searching for TK5...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name?.contains("TK5") == true || peripheral.name?.contains("ring") == true {
            print("[FOUND] RSSI: \(RSSI)")
            self.ring = peripheral
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[CONNECTED] Discovering characteristics...")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics {
            let uuid = char.uuid.uuidString.uppercased()
            if char.properties.contains(.notify) { peripheral.setNotifyValue(true, for: char) }
            
            // USE ONLY THE MOST STANDARD JIELLI COMMAND
            if uuid == "AE01" || uuid.contains("6E400002") {
                print("[ACTION] Initializing Handshake on \(uuid)...")
                sendPacket(0x21, subData: [], to: peripheral, for: char, delay: 2.0)
                sendPacket(0x69, subData: [0x01, 0x01], to: peripheral, for: char, delay: 5.0)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                    print("[LOOP] Keep-Alive active. HOLD STILL.")
                    self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                        self.sendPacket(0x1E, subData: [0x33], to: peripheral, for: char, delay: 0)
                    }
                }
            }
        }
    }

    func sendPacket(_ cmd: UInt8, subData: [UInt8], to peripheral: CBPeripheral, for char: CBCharacteristic, delay: Double) {
        let block = {
            var packet = [UInt8](repeating: 0, count: 16)
            packet[0] = cmd
            for (i, byte) in subData.enumerated() { if i < 14 { packet[i+1] = byte } }
            packet[15] = UInt8(packet[0..<15].reduce(0) { $0 + Int($1) } % 256)
            peripheral.writeValue(Data(packet), for: char, type: .withoutResponse)
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block) } else { block() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        let uuid = characteristic.uuid.uuidString.uppercased()

        if uuid.contains("2A37") && bytes.count >= 2 {
            let flags = bytes[0]
            let hr = bytes[1]
            let contact = (flags & 0x06) != 0
            if hr > 0 {
                print(">>> SUCCESS! [HEART RATE]: \(hr) BPM")
            } else {
                print("[STATUS] Waiting for signal... Contact: \(contact ? "OK" : "NO") (Flags: \(String(format:"%02x", flags)))")
            }
        }
    }
}

let monitor = DeepLockMonitor()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 300))
