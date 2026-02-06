// Demo 2: CTFE Lookup Table
// Generate a CRC32 table at compile time - zero runtime cost!

// This function runs at compile time to build the lookup table
int[256] makeCrcTable() {
    int[256] table;
    
    for (int i = 0; i < 256; i++) {
        int crc = i;
        for (int j = 0; j < 8; j++) {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;  // CRC32 polynomial
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    
    return table;
}

// Table is computed at compile time - embedded directly in WASM
enum crcTable = makeCrcTable();

// Runtime CRC32 computation using the pre-computed table
int crc32(ubyte[] data) {
    int crc = 0xFFFFFFFF;
    
    for (int i = 0; i < data.length; i++) {
        int index = (crc ^ data[i]) & 0xFF;
        crc = (crc >> 8) ^ crcTable[index];
    }
    
    return crc ^ 0xFFFFFFFF;
}

// Test: CRC32 of "123456789" should be 0xCBF43926
int main() {
    // For now, just verify the table was generated correctly
    // First entry should be 0, entry[1] should be 0x77073096
    return crcTable[1];  // Expected: 0x77073096 = 1996959894
}
