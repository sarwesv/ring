import Foundation
import CoreBluetooth

class RingSerialTerminal: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var ring: CBPeripheral?
    var keepAliveTimer: Timer?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("--- TK5 Serial Terminal Initialized ---")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("[SCAN] Searching for TK5...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name?.contains("TK5") == true || peripheral.name?.contains("ring") == true {
            print("[FOUND] RSSI: \(RSSI) | ID: \(peripheral.identifier)")
            self.ring = peripheral
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[CONNECTED] Discovering ALL services...")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            print("  - Found Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics {
            let uuid = char.uuid.uuidString.uppercased()
            print("    * Found Char: \(uuid)")
            if char.properties.contains(.notify) { peripheral.setNotifyValue(true, for: char) }
            
            // Check for PulseLoop characteristics OR Jieli ones
            if uuid == "33F3" || uuid == "AE01" || uuid.contains("6E400002") {
                startProtocolSequence(peripheral, char: char)
            }
        }
    }

    func startProtocolSequence(_ peripheral: CBPeripheral, char: CBCharacteristic) {
        let uuid = char.uuid.uuidString.uppercased()
        print("[ACTION] Dynamic Impersonation on \(uuid)...")

        // 1. Generate Dynamic App Identity Packet
        // Pattern from Log: 48 1d 0e 00 00 [4-byte Timestamp LE] 03 00...
        let timestamp = UInt32(Date().timeIntervalSince1970)
        var packetBytes = [UInt8](repeating: 0, count: 20)
        packetBytes[0] = 0x48
        packetBytes[1] = 0x1d
        packetBytes[2] = 0x0e
        packetBytes[5] = UInt8(timestamp & 0xFF)
        packetBytes[6] = UInt8((timestamp >> 8) & 0xFF)
        packetBytes[7] = UInt8((timestamp >> 16) & 0xFF)
        packetBytes[8] = UInt8((timestamp >> 24) & 0xFF)
        packetBytes[9] = 0x03

        let dynamicHex = packetBytes.map { String(format: "%02x", $0) }.joined()
        print("[AUTH] Generated Activation Key: \(dynamicHex)")

        send20Packet(dynamicHex, to: peripheral, for: char, delay: 1.0)

        // 2. Mode Switch (Force Normal)
        send20Packet("5200010000000000000000000000000000000000", to: peripheral, for: char, delay: 2.5)

        // 3. Status Query
        send20Packet("0c00000000000000000000000000000000000000", to: peripheral, for: char, delay: 4.0)

        // 4. Heart Rate Start Loop
        self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            print("[LOOP] Pulse Request...")
            self.send20Packet("14b4000000000000000000000000000000000000", to: peripheral, for: char, delay: 0)
        }
    }

    func send20Packet(_ hex: String, to peripheral: CBPeripheral, for char: CBCharacteristic, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var data = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                data.append(UInt8(hex[index..<next], radix: 16)!)
                index = next
            }
            peripheral.writeValue(data, for: char, type: .withoutResponse)
        }
    }

    func send16Packet(_ cmd: UInt8, subData: [UInt8], to peripheral: CBPeripheral, for char: CBCharacteristic, delay: Double) {
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
        
        // ATTEMPT ASCII DECODING
        if let asciiString = String(data: data, encoding: .utf8) {
            let cleanString = asciiString.trimmingCharacters(in: .controlCharacters)
            if !cleanString.isEmpty {
                print("[CONSOLE]: \(cleanString)")
            }
        } else {
            // If not ASCII, print hex as fallback
            let bytes = [UInt8](data)
            print("[DATA] \(characteristic.uuid.uuidString.prefix(4)): \(bytes.map{String(format:"%02x",$0)}.joined(separator:" "))")
        }
    }
}

let terminal = RingSerialTerminal()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 120))
print("--- Session Ended ---")
