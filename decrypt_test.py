from Crypto.Cipher import AES
import binascii

# The encrypted 16-byte payload found in the logs
encrypted_hex = "9e43df377b3a46ce751634667e215de5"
ciphertext = binascii.unhexlify(encrypted_hex)

# Common keys
keys = [
    b"first_bond_key_1",
    b"0123456789abcdef",
    bytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16]),
    bytes([0x00] * 16),
    bytes([0xFF] * 16),
    # Try some other variations
    b"0000000000000000",
    b"1234567890123456"
]

print(f"Target Ciphertext: {encrypted_hex}")

for key in keys:
    try:
        cipher = AES.new(key, AES.MODE_ECB)
        decrypted = cipher.decrypt(ciphertext)
        dec_hex = binascii.hexlify(decrypted).decode()
        print(f"Key: {key} -> Result: {dec_hex}")
        
        # Check for common headers: 0x01 (Steps), 0x69 (HR), 0x21 (Login), 0x07 (Status), 0x00 (Firmware)
        if decrypted[0] in [0x01, 0x69, 0x21, 0x07, 0x00, 0x03]:
            print("!!! POTENTIAL MATCH FOUND !!!")
    except Exception as e:
        print(f"Error with key {key}: {e}")
