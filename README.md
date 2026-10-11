# ring

Reverse-engineering and talking to a **TK9** BLE smart ring — a native macOS
client plus a browser dashboard you can run from GitHub Pages.

**Live dashboard:** https://sarwesv.github.io/ring/ (Chrome or Edge, desktop)

---

## What this is

The TK9 is a cheap BLE smart ring. It does **not** use the Nordic UART
protocol that the older TK5 scripts in this repo target — it exposes a custom
GATT service and a simple cleartext framing, which this project maps out and
implements two ways:

- **`tk9_fetch.swift`** — a native macOS CoreBluetooth command-line client.
- **`index.html`** — a Web Bluetooth dashboard (runs client-side in the
  browser; this is what GitHub Pages serves).

## The TK9 protocol

| | |
|---|---|
| Data service | `56FF` |
| Write characteristic (host → ring) | `33F3` |
| Notify characteristic (ring → host) | `33F4` |
| Framing | fixed **20 bytes**, byte 0 = command id, little-endian payload, zero-padded |
| Encryption | none — cleartext |

### Commands / opcodes

| Opcode | Meaning | Notes |
|--------|---------|-------|
| `0x01` | Time sync | payload = local epoch, `u32` LE |
| `0x02` | Query current activity | ring replies with `0x03` |
| `0x03` | Activity response | `ts(4) · steps(4) · distance(4) · calories(4)`, all LE |
| `0x0b` | Battery (broadcast) | byte 1 = percent |
| `0x0c` | Device status | bytes 5–8 = device id tail |
| `0x14` / `0x15` | Heart-rate start / stop | HR frame: `ts(4)` then BPM at byte 5 |
| `0x23` | SpO2 start | streams `0x24` result frames |
| `0x24` | SpO2 result | all-zero payload = measuring; value at byte 5; `0x28` ends the session |
| `0x10` | History query | not yet implemented |

> **SpO2 caveat:** the protocol is fully decoded, but this hardware often fails
> to compute a valid on-device SpO2 (it returns a non-physiological status
> rather than a percentage). The clients report a reading only when byte 5 is in
> the physiological 70–100 range, and flag "no valid reading" otherwise.

## Native client — `tk9_fetch.swift`

Runs a fetch plan and decodes the responses: time-sync, activity, status,
battery, heart rate, and SpO2.

```sh
swift tk9_fetch.swift
```

Requirements: macOS with the Swift toolchain, and Bluetooth permission granted
to your terminal (**System Settings → Privacy & Security → Bluetooth**). The
ring's CoreBluetooth identifier is hard-coded near the top of the file — update
`RING_ID` if you're pairing a different unit, or let it fall back to scanning by
name.

## Web dashboard — `index.html`

A zero-dependency page that connects to the ring over the **Web Bluetooth API**
and shows live battery, steps, heart rate, SpO2 and the ring clock, with a
button to set the time.

- Open **https://sarwesv.github.io/ring/** in **Chrome or Edge on desktop**
  (Safari and Firefox don't support Web Bluetooth).
- Pick the model in the dropdown and click **Connect ring**, then choose the
  ring in the browser's device picker.
- GitHub Pages serves it over HTTPS, which Web Bluetooth requires. The page is
  static — all BLE happens in your browser; nothing is sent to any server.

### Model dropdown

- **TK9** — full decoding (validated against real hardware).
- **TK5** — a different stack (Nordic UART, `6E400001…`). The dashboard connects
  and logs raw frames, but does **not** decode them; that protocol was never
  validated here.

## Repo layout

| Path | What |
|------|------|
| `tk9_fetch.swift` | native macOS TK9 client |
| `index.html` | Web Bluetooth dashboard (served by Pages) |
| `.nojekyll` | tells Pages to serve files as-is (skip the Jekyll build) |
| `logs/` | raw BLE capture logs from the reverse-engineering work |
| `ring-discovery/`, `tk5_*.swift`, `ring_*.swift`, `*.py` | earlier TK5 exploration (Nordic UART / Jieli), kept for reference |

## Credits

TK9 protocol confirmed against the community write-up of the `56FF` AliExpress
ring family, then validated live against the hardware.
