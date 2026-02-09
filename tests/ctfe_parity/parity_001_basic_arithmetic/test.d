// CTFE Parity Test: Basic arithmetic
// Both wasm and native backends should compute the same value

int compute(int a, int b) {
    return a * b + (a - b);
}

enum RESULT = compute(7, 3);  // Should be 7*3 + (7-3) = 21 + 4 = 25

int main() {
    return RESULT;
}
