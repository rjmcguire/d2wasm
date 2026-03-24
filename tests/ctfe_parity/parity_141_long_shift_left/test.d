// Shift left on long values — result exceeds 32-bit range
int compute() {
    long x = 1;
    long shifted = x << 40;  // 1099511627776
    // Shift back to verify round-trip
    long back = shifted >> 40;
    return cast(int)back;  // should be 1
}

enum RESULT = compute();
int main() { return RESULT; }
