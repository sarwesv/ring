import binascii

def analyze_log(file_path):
    print(f"Analyzing {file_path} for Heart Rate sequences...")
    try:
        with open(file_path, "rb") as f:
            data = f.read()
    except Exception as e:
        print(f"Error reading file: {e}")
        return

    # Looking for GATT Write (0x12) and Notifications (0x1b)
    # Packet Logger files often have a specific header, but raw searching for UUIDs and 20-byte patterns works well.
    
    # Common TK5 UUIDs in hex
    uuids = {
        "AE01": "ae01",
        "AE02": "ae02",
        "2A37": "2a37",
        "33F3": "33f3",
        "33F4": "33f4"
    }

    print("--- Searching for Writes and Notifications ---")
    
    # We'll look for 16 and 20 byte patterns
    # A common pattern is CMD + data + [optional checksum]
    
    # Find all 20-byte sequences that start with known command IDs
    cmd_ids = [0x01, 0x0c, 0x14, 0x15, 0x21, 0x48, 0x52, 0xff]
    
    found_sequences = []
    for i in range(len(data) - 20):
        if data[i] in cmd_ids:
            # Check for 20-byte packet (PulseLoop style)
            # Many end with 0000000000
            seq_20 = data[i:i+20]
            if seq_20[15:20] == b'\x00\x00\x00\x00\x00':
                found_sequences.append(("20-BYTE", seq_20.hex()))
            
            # Check for 16-byte packet (Colmi style)
            seq_16 = data[i:i+16]
            checksum = sum(seq_16[0:15]) & 0xFF
            if seq_16[15] == checksum:
                found_sequences.append(("16-BYTE", seq_16.hex()))

    # Deduplicate and print
    unique_seq = sorted(list(set(found_sequences)))
    for t, s in unique_seq:
        print(f"[{t}] {s}")

    # Specific check for Heart Rate values (2A37)
    # The standard HR notification is 2 bytes: [Flags, BPM]
    # We look for a pattern where a notification flag is followed by a non-zero BPM
    print("\n--- Searching for non-zero Heart Rate Notifications ---")
    for i in range(len(data) - 10):
        # Look for possible 2A37 data: [Flags, BPM]
        # Flags are usually 0x00, 0x04, 0x06
        if data[i] in [0x00, 0x06] and 40 < data[i+1] < 180:
             # Check if this byte is part of a notification record
             # (This is a fuzzy search, but non-zero HR values are rare in raw dumps)
             print(f"Possible HR Value: {data[i+1]} BPM at offset {i} (Hex: {data[i:i+2].hex()})")

analyze_log("../../Downloads/Jun14221pmlog.pklg")
