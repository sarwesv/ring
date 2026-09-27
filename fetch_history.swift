import Foundation
import CoreBluetooth
import CommonCrypto

class HistoryFetcher: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var ring: CBPeripheral?
    let zeroKey = Data(repeating: 0x00, count: 16)
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("--- Ring History Fetcher Initialized ---")
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
            
            if uuid == "AE01" || uuid.contains("6E400002") {
                startHistorySequence(peripheral, char: char)
            }
        }
    }

    func startHistorySequence(_ peripheral: CBPeripheral, char: CBCharacteristic) {
        print("[ACTION] Requesting History from \(char.uuid)...")
        
        let now = Date()
        let calendar = Calendar.current
        let comp = calendar.dateComponents([.year, .month, .day], from: now)
        var dateData = [UInt8](repeating: 0, count: 3)
        dateData[0] = decimalToBcd(UInt8(comp.year! % 100))
        dateData[1] = decimalToBcd(UInt8(comp.month!))
        dateData[2] = decimalToBcd(UInt8(comp.day!))
        
        sendPacket(0x21, subData: [], to: peripheral, for: char, delay: 1.0)
        
        // Try multiple history variants
        print("[FETCH] Requesting HR History (0x15)...")
        sendPacket(0x15, subData: dateData, to: peripheral, for: char, delay: 3.0)
        
        print("[FETCH] Requesting History Stream (0x16)...")
        sendPacket(0x16, subData: [0x00], to: peripheral, for: char, delay: 5.0)
        
        print("[FETCH] Requesting Step History (0x43)...")
        sendPacket(0x43, subData: [0x00, 0x0f, 0x00, 0x5f, 0x01], to: peripheral, for: char, delay: 7.0)
    }

    func sendPacket(_ cmd: UInt8, subData: [UInt8], to peripheral: CBPeripheral, for char: CBCharacteristic, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var packet = [UInt8](repeating: 0, count: 16)
            packet[0] = cmd
            for (i, byte) in subData.enumerated() { if i < 14 { packet[i+1] = byte } }
            packet[15] = UInt8(packet[0..<15].reduce(0) { $0 + Int($1) } % 256)
            peripheral.writeValue(Data(packet), for: char, type: .withoutResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        let uuid = characteristic.uuid.uuidString.uppercased()
        
        if uuid == "AE02" || uuid.contains("6E400003") {
            print("[\(Date().description)] RAW [\(uuid)]: \(bytes.map{String(format:"%02x",$0)}.joined(separator:" "))")
        }

        if bytes.count == 17 || bytes.count == 16 {
            let offset = (bytes.count == 17) ? 1 : 0
            let payload = data.subdata(in: offset..<(16+offset))
            if let decrypted = decryptAES128ECB(data: payload, key: zeroKey) {
                let dBytes = [UInt8](decrypted)
                handleDecryptedHistory(dBytes)
            }
        }
    }

    func handleDecryptedHistory(_ bytes: [UInt8]) {
        let cmd = bytes[0]
        if cmd == 0x15 || cmd == 0x16 {
            let readings = bytes[8...14].filter { $0 > 0 }
            if !readings.isEmpty {
                print(">>> [HISTORY DATA] Values: \(readings.map{String($0)}.joined(separator: ", "))")
            }
        } else if cmd == 0x43 {
            let steps = UInt16(bytes[9]) | (UInt16(bytes[10]) << 8)
            if steps > 0 {
                print(">>> [HISTORY STEPS] Total: \(steps) steps")
            }
        }
    }

    func decryptAES128ECB(data: Data, key: Data) -> Data? {
        let keyBytes = [UInt8](key)
        let dataBytes = [UInt8](data)
        var decryptedBytes = [UInt8](repeating: 0, count: 16)
        var numBytesDecrypted: Int = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), keyBytes, kCCKeySizeAES128, nil, dataBytes, 16, &decryptedBytes, 16, &numBytesDecrypted)
        return status == kCCSuccess ? Data(decryptedBytes) : nil
    }

    func decimalToBcd(_ val: UInt8) -> UInt8 { return ((val / 10) << 4) | (val % 10) }
}

let fetcher = HistoryFetcher()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 45))
print("\n--- History fetch finished ---")
