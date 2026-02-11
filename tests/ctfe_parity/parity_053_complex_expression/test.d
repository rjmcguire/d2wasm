int test() {
    // Test complex nested expressions and operator precedence
    int a = 2 + 3 * 4;         // 14
    int b = (2 + 3) * 4;       // 20
    int c = 100 / 3 % 7;       // 33 % 7 = 5
    int d = 1 << (2 + 1);      // 8
    int e = (a | b) & 0x1F;    // (14 | 20) = 30, 30 & 31 = 30

    // Chained comparisons in conditions
    int result = 0;
    if (a < b && b > c) {
        result = result + 1;   // true: 14<20 && 20>5
    }
    if (c <= d || a >= 100) {
        result = result + 10;  // true: 5<=8
    }
    if (!(a == b)) {
        result = result + 100; // true: 14 != 20
    }

    return a + b + c + d + e + result;  // 14+20+5+8+30+111 = 188
}

enum RESULT = test();
int main() { return RESULT; }
