import binascii

def analyze_start_stop(file_path):
    print(f"Analyzing {file_path} for Start/Stop sequence...")
    try:
        with open(file_path, "rb") as f:
            data = f.read()
    except Exception as e:
        print(f"Error reading file: {e}")
        return

    # Jieli/PulseLoop identifiers
    cmd_ids = [0x01, 0x0c, 0x14, 0x15, 0x21, 0x48, 0x52, 0xff, 0x06]
    
    print("--- Time-Ordered Sequence of Commands ---")
    
    found_events = []
    
    # We'll do a simple sweep. pklg files are binary but often embed the raw ATT packets.
    for i in range(len(data) - 20):
        # 16-byte check
        seq_16 = data[i:i+16]
        checksum = sum(seq_16[0:15]) & 0xFF
        if seq_16[15] == checksum and seq_16[0] in cmd_ids:
            found_events.append((i, "16-BYTE", seq_16.hex()))
            
        # 20-byte check
        seq_20 = data[i:i+20]
        if seq_20[0] in cmd_ids and seq_20[15:20] == b'\x00\x00\x00\x00\x00':
             found_events.append((i, "20-BYTE", seq_20.hex()))

    # Deduplicate closely spaced hits (common in raw pklg offsets)
    last_off = -100
    for off, t, s in sorted(found_events):
        if off > last_off + 16:
            print(f"Offset {off:06x}: [{t}] {s}")
            last_off = off

    print("\n--- Notification Frequency ---")
    hr_notifications = []
    for i in range(len(data) - 2):
        # Look for [00, BPM] or [06, BPM]
        if data[i] in [0x00, 0x06, 0x04] and 40 < data[i+1] < 180:
            hr_notifications.append((i, data[i+1]))
    
    print(f"Found {len(hr_notifications)} possible HR data points.")
    for off, bpm in hr_notifications[:10]:
        print(f"Offset {off:06x}: BPM {bpm}")

analyze_start_stop("../../Downloads/Jun14245pmlog.pklg")
