int test() {
    int a = 0xFF;
    int b = 0x0F;
    int r1 = a & b;   // 0x0F = 15
    int r2 = a | b;   // 0xFF = 255
    int r3 = a ^ b;   // 0xF0 = 240
    int r4 = 1 << 4;  // 16
    int r5 = 64 >> 2; // 16
    return r1 + r2 + r3 + r4 + r5;  // 15+255+240+16+16 = 542
}

enum RESULT = test();

int main() { return RESULT; }
