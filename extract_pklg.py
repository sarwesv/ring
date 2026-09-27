import struct

def parse_pklg(file_path):
    print(f"Analyzing {file_path}...")
    with open(file_path, "rb") as f:
        data = f.read()
    
    # Simple search for GATT Write patterns (ATT OpCode 0x12 or 0x52)
    # Most 20-byte packets are easy to spot in the binary stream
    found_writes = []
    
    # Look for sequences of 16 or 20 bytes that start with common Jieli headers
    # (0x01, 0x21, 0x69, 0x48, 0x0c, etc.)
    potential_headers = [0x01, 0x21, 0x69, 0x48, 0x0c, 0x03, 0x52, 0xff]
    
    for i in range(len(data) - 20):
        if data[i] in potential_headers:
            # Check if this looks like a 16-byte packet (checksummed)
            candidate = data[i:i+16]
            checksum = sum(candidate[0:15]) & 0xFF
            if candidate[15] == checksum:
                found_writes.append(("16-BYTE", candidate.hex()))
                continue
            
            # Check if this looks like a 20-byte packet
            # (Usually lots of zeros at the end)
            candidate_20 = data[i:i+20]
            if candidate_20[15:20] == b'\x00\x00\x00\x00\x00':
                found_writes.append(("20-BYTE", candidate_20.hex()))

    # Print unique found commands
    unique_writes = sorted(list(set(found_writes)))
    for type, hex_val in unique_writes:
        print(f"[{type}] Potential Command: {hex_val}")

parse_pklg("../../../../tmp/ringInitializatonLogs.pklg")
