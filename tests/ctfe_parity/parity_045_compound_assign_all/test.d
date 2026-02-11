int test() {
    int x = 100;
    x += 50;    // 150
    x -= 30;    // 120
    x *= 2;     // 240
    x /= 3;     // 80
    x %= 7;     // 80 % 7 = 3

    int y = 0xFF;
    y &= 0x0F;  // 15
    y |= 0x30;  // 63
    y ^= 0x0A;  // 53

    int z = 1;
    z <<= 4;    // 16
    z >>= 1;    // 8

    return x + y + z;  // 3 + 53 + 8 = 64
}

enum RESULT = test();
int main() { return RESULT; }
