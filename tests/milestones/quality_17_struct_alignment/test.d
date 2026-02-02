// Test: struct alignment and padding
// bool is 1 byte, int is 4 bytes, so Padded needs 3 bytes padding

struct Padded {
    bool b;   // offset 0, size 1
              // 3 bytes padding
    int x;    // offset 4, size 4
}

int main() {
    return Padded.sizeof;  // Should be 8, not 5
}
