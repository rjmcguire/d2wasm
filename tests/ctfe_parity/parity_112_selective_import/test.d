// CTFE Parity Test: Selective import with CTFE
// Both wasm and native backends should resolve selective imports
// and evaluate the imported function at compile time.

import helper : add, product = mul;

enum A = add(17, 8);        // 25
enum B = product(5, 10);    // 50

int main() {
    return A + B;  // 75
}
