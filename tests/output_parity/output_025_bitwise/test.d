int test() {
    int a = 0xFF;
    int b = 0x0F;
    int r1 = a & b;
    int r2 = a | b;
    int r3 = a ^ b;
    int r4 = 1 << 4;
    int r5 = 64 >> 2;
    return r1 + r2 + r3 + r4 + r5;
}

int main() { return test(); }
