// Milestone 120: CTFE CRC32 Lookup Table
// Generate a 256-entry CRC32 table at compile time
//
// This tests:
// - Static arrays (int[256])
// - For loops in CTFE
// - Nested loops in CTFE
// - Bitwise operations (>>, ^, &)
// - Array indexing in CTFE
// - Enum initialized from CTFE function

// Build the CRC32 lookup table at compile time
int[256] makeCrcTable() {
    int[256] table;
    
    for (int i = 0; i < 256; i++) {
        int crc = i;
        for (int j = 0; j < 8; j++) {
            if ((crc & 1) != 0) {
                crc = (crc >>> 1) ^ 0xEDB88320;
            } else {
                crc = crc >>> 1;
            }
        }
        table[i] = crc;
    }
    
    return table;
}

// Table computed at compile time
enum crcTable = makeCrcTable();

int main() {
    // Verify table entry [1] = 0x77073096 = 1996959894
    // This confirms the CTFE ran correctly
    return crcTable[1];
}
