import Foundation
import CoreBluetooth

class TK5OfficialMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var ring: CBPeripheral?
    var timer: Timer?
    var lastBPM: Int = 0
    var lastBPMTime: Date = Date()
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("\n💎 TK5 OFFICIAL PROTOCOL MONITOR 💎")
        print("-----------------------------------")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("🔍 Searching...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name?.contains("TK5") == true || peripheral.name?.contains("ring") == true {
            print("✅ Found Ring: \(peripheral.name!)")
            self.ring = peripheral
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("🔗 Connected. Synchronizing...")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            let uuid = char.uuid.uuidString.uppercased()
            if char.properties.contains(.notify) { peripheral.setNotifyValue(true, for: char) }
            
            if uuid == "AE01" || uuid.contains("6E400002") {
                startOfficialSequence(peripheral, char: char)
            }
        }
    }

    func startOfficialSequence(_ peripheral: CBPeripheral, char: CBCharacteristic) {
        let ts = UInt32(Date().timeIntervalSince1970)
        
        print("[AUTH] Initializing Verified Protocol...")
        
        // 1. Activation Packet (16-byte variant from Log)
        var act = [UInt8](repeating: 0, count: 16)
        act[0] = 0x48; act[1] = 0x65; act[2] = 0x02; act[4] = 0x01; act[5] = 0x0e; act[6] = 0x06; act[7] = 0x01
        act[8] = UInt8(ts & 0xFF); act[9] = UInt8((ts >> 8) & 0xFF); act[11] = 0x05; act[13] = 0x51
        act[15] = UInt8(act[0..<15].reduce(0) { $0 + Int($1) } % 256)
        peripheral.writeValue(Data(act), for: char, type: .withoutResponse)
        
        // 2. THE GOLDEN 06 START COMMAND (From Log Offset 0017a7)
        // 06 01 07 00 52 1a 55 12 00 00 00 59 be 2e 6a [CS]
        var startComplex = [UInt8](repeating: 0, count: 16)
        startComplex[0] = 0x06; startComplex[1] = 0x01; startComplex[2] = 0x07; startComplex[3] = 0x00
        startComplex[4] = 0x52; startComplex[5] = 0x1a; startComplex[6] = 0x55; startComplex[7] = 0x12
        startComplex[11] = 0x59; startComplex[12] = 0xbe; startComplex[13] = 0x2e; startComplex[14] = 0x6a
        startComplex[15] = UInt8(startComplex[0..<15].reduce(0) { $0 + Int($1) } % 256)
        
        print("[START] Sending High-Freq Measurement Trigger...")
        peripheral.writeValue(Data(startComplex), for: char, type: .withoutResponse)

        // 3. Keep-Alive & Poll Loop (Every 2s)
        self.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            // Status Query (20-byte)
            var keep = [UInt8](repeating: 0, count: 20)
            keep[0] = 0x0c
            peripheral.writeValue(Data(keep), for: char, type: .withoutResponse)
            
            // Real-time Data Request (0x02 inside 20-byte)
            var req = [UInt8](repeating: 0, count: 20)
            req[0] = 0x01; req[7] = 0x02 // As seen in log
            peripheral.writeValue(Data(req), for: char, type: .withoutResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        let uuid = characteristic.uuid.uuidString.uppercased()

        // 1. Standard HR Profile (The Log showed this as 00 XX)
        if uuid.contains("2A37") && bytes.count >= 2 {
            let bpm = Int(bytes[1])
            if bpm > 0 {
                print("💓 HEART RATE: \(bpm) BPM [LIVE]")
                self.lastBPM = bpm
            }
        }
        
        // 2. ASCII Console Parsing
        if let log = String(data: data, encoding: .utf8) {
            let clean = log.trimmingCharacters(in: .controlCharacters)
            if clean.contains("Save hr") {
                let val = clean.components(separatedBy: CharacterSet(charactersIn: "<>")).filter { Int($0) != nil }.first ?? "?"
                print("💓 HEART RATE: \(val) BPM [CONSOLE]")
            } else if clean.contains("STEPS") {
                print("👟 \(clean.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }
}

let monitor = TK5OfficialMonitor()
RunLoop.main.run()
