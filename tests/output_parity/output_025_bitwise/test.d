int test() {
    int a = 0x3F;
    int b = 0x0F;
    int r1 = a & b;     // 15
    int r2 = a | b;     // 63
    int r3 = a ^ b;     // 48
    int r4 = 1 << 4;    // 16
    int r5 = 64 >> 2;   // 16
    return r1 + r2 + r3 + r4 + r5;
}

int main() { return test(); }
