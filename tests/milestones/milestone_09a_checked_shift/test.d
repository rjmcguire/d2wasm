// Test checked shift operator functions (valid shifts)

int main() {
    int a = opShiftLeft(1, 4);       // 1 << 4 = 16
    int b = opShiftRight(a, 2);      // 16 >> 2 = 4
    return a + b;                     // 20
}
