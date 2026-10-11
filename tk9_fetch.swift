import Foundation
import CoreBluetooth

// TK9 data fetcher — service 56FF (write 33F3 / notify 33F4), plus standard
// Battery Service 180F/2A19. Frames are a fixed 20 bytes: byte 0 = command id,
// rest little-endian payload, zero-padded. No checksum, cleartext.
// Protocol ref: sakshambhutani.xyz AliExpress 56FF smart-ring writeup, cross-
// checked against live capture from this ring.

let RING_ID = UUID(uuidString: "667D4770-5C33-C6C7-3575-A441F0A5D2BC")!

let SVC_DATA = CBUUID(string: "56FF")
let CH_WRITE = CBUUID(string: "33F3")   // host -> ring
let CH_NOTIFY = CBUUID(string: "33F4")  // ring -> host
let SVC_BATT = CBUUID(string: "180F")
let CH_BATT = CBUUID(string: "2A19")

// Opcodes (byte 0).
enum Op: UInt8 {
    case timeSync = 0x01
    case activityQuery = 0x02
    case activityResp = 0x03
    case status = 0x0c
    case battery = 0x0b
    case history = 0x10
    case hrStart = 0x14
    case hrStop = 0x15
    case spo2Start = 0x23
    case spo2Resp = 0x24
}

// A queued step: a 20-byte command to write, a label, and how long to wait
// for notifications before moving on.
struct Step {
    let label: String
    let frame: [UInt8]      // empty => battery read instead of a 33F3 write
    let readBattery: Bool
    let wait: TimeInterval
}

func cmd(_ op: Op, _ payload: [UInt8] = []) -> [UInt8] {
    var f = [op.rawValue] + payload
    f += Array(repeating: 0, count: max(0, 20 - f.count))
    return Array(f.prefix(20))
}

func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
}

// Time sync: 01 | local-epoch(u32 LE). The ring stores wall-clock time, so we
// send UTC epoch shifted by the local UTC offset (same u32 form its own frames
// use for timestamps).
func timeSyncFrame() -> [UInt8] {
    // Do the offset math signed (UTC offset can be negative), then narrow.
    let local = Int(Date().timeIntervalSince1970) + TimeZone.current.secondsFromGMT()
    return cmd(.timeSync, le32(UInt32(local)))
}

func u32le(_ b: ArraySlice<UInt8>) -> UInt32 {
    let a = Array(b)
    guard a.count >= 4 else { return 0 }
    return UInt32(a[0]) | UInt32(a[1]) << 8 | UInt32(a[2]) << 16 | UInt32(a[3]) << 24
}

final class TK9Fetcher: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var ring: CBPeripheral?
    var writeChar: CBCharacteristic?
    var battChar: CBCharacteristic?
    var ready = false

    // Fetch-only plan: query current activity, status, battery, then take a
    // live HR and SpO2 reading. Nothing here alters stored settings except
    // the sensor sessions the ring starts for a measurement.
    lazy var plan: [Step] = [
        Step(label: "Set ring clock (time-sync)",
             frame: timeSyncFrame(), readBattery: false, wait: 2.0),
        Step(label: "Current activity (steps/distance/calories)",
             frame: cmd(.activityQuery), readBattery: false, wait: 2.0),
        Step(label: "Device status", frame: cmd(.status), readBattery: false, wait: 2.0),
        Step(label: "Heart-rate measurement (start)",
             frame: cmd(.hrStart), readBattery: false, wait: 12.0),
        Step(label: "Heart-rate measurement (stop)",
             frame: cmd(.hrStop), readBattery: false, wait: 1.0),
        Step(label: "SpO2 measurement (start) — wear the ring, ~25s",
             frame: cmd(.spo2Start), readBattery: false, wait: 30.0),
    ]
    var idx = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: central

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            print("[ERROR] Bluetooth not ready (state \(c.state.rawValue)).")
            return
        }
        if let p = c.retrievePeripherals(withIdentifiers: [RING_ID]).first {
            print("[CONNECT] retrieved known TK9")
            ring = p; p.delegate = self; c.connect(p, options: nil)
        } else {
            print("[SCAN] TK9 not cached; scanning...")
            c.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData adv: [String: Any], rssi RSSI: NSNumber) {
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard ring == nil, name.localizedCaseInsensitiveContains("TK9") else { return }
        ring = p; p.delegate = self; c.stopScan(); c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("[CONNECTED] discovering services...")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("[ERROR] connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    // MARK: peripheral

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            switch ch.uuid {
            case CH_WRITE: writeChar = ch
            case CH_NOTIFY: p.setNotifyValue(true, for: ch)
            case CH_BATT: battChar = ch
            default: break
            }
        }
        if writeChar != nil, !ready {
            ready = true
            print("[READY] channels bound. Starting fetch plan.\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runStep() }
        }
    }

    func runStep() {
        guard let p = ring else { return }
        guard idx < plan.count else {
            print("\n[DONE] All steps complete.")
            exit(0)
        }
        let step = plan[idx]
        print("── \(step.label) ──")
        if step.readBattery, let b = battChar {
            p.readValue(for: b)
        } else if !step.frame.isEmpty, let w = writeChar {
            let data = Data(step.frame)
            let mode: CBCharacteristicWriteType =
                w.properties.contains(.write) ? .withResponse : .withoutResponse
            print("   -> write 33F3: \(hex(step.frame))")
            p.writeValue(data, for: w, type: mode)
        }
        let waited = idx
        DispatchQueue.main.asyncAfter(deadline: .now() + step.wait) {
            if self.idx == waited { self.idx += 1; self.runStep() }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let error = error { print("   [ERR] \(ch.uuid): \(error.localizedDescription)"); return }
        guard let d = ch.value else { return }
        if ch.uuid == CH_BATT {
            print("   battery = \(d.first.map(String.init) ?? "?")%")
            return
        }
        let b = [UInt8](d)
        print("   <- notify: \(hex(b))")
        decode(b)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let error = error { print("   [write err] \(error.localizedDescription)") }
    }

    // MARK: decode

    func decode(_ b: [UInt8]) {
        guard let first = b.first, let op = Op(rawValue: first) else { return }
        switch op {
        case .activityResp:
            // 03 | ts(4) | steps(4) | distance(4) | calories(4)
            let ts = u32le(b[1..<5])
            let steps = u32le(b[5..<9])
            let dist = u32le(b[9..<13])
            let cals = u32le(b[13..<17])
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            print("   => steps=\(steps) distance=\(dist) calories=\(cals) devTime=\(date) (ts=\(ts))")
        case .battery:
            // 0b <percent> ...  (observed 0x5c/0x5d ~= 92-93%)
            if b.count >= 2 { print("   => battery = \(b[1])%") }
        case .status:
            // Observed: 0c a0 00 | 02 03 <devId:4> ...  (devId tail matches advert)
            if b.count >= 9 {
                let id = b[5..<9].map { String(format: "%02x", $0) }.joined()
                print("   => status; device-id tail=\(id)")
            }
        case .hrStart:
            // 14 | ts(4) | BPM | ...  (confirmed from live readings: byte 5)
            if b.count >= 6, b[5] > 0 {
                let ts = u32le(b[1..<5])
                print("   => heart rate = \(b[5]) BPM (devTime ts=\(ts))")
            }  // else: start ack (all-zero payload)
        case .spo2Resp:
            // 24 | ts(4) | value.  All-zero payload = still measuring.
            // A physiological value (70-100) is a real %; anything else is a
            // completion/quality status (e.g. 5 = no valid lock), not a %.
            guard b.dropFirst().contains(where: { $0 != 0 }) else { return } // measuring
            let v = Int(b[5])
            if (70...100).contains(v) {
                print("   => SpO2 = \(v)%")
            } else {
                print("   => SpO2 measurement ended with no valid reading (status=\(v)) — wear snug/still")
            }
        case .spo2Start:
            break // just the start ack
        default:
            break
        }
    }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

let f = TK9Fetcher()
print("[INFO] TK9 fetch — reads activity/status/battery and takes HR + SpO2 readings.")
print("[INFO] Keep the ring on a finger for HR/SpO2 to produce real values.\n")
RunLoop.main.run(until: Date(timeIntervalSinceNow: 60))
print("[END] window closed.")
