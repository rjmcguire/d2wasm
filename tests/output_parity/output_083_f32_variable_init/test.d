// Output Parity Test: float (f32) variable initialization
// Verifies that float locals are correctly initialized, stored, and loaded

int main() {
    float x = 1.5;
    float y = 2.5;

    // Verify basic init: 1.5 + 2.5 = 4.0
    float sum = x + y;
    if (sum != 4.0)
        return 1;

    // Verify default init is 0.0
    float z;
    if (z != 0.0)
        return 2;

    // Verify reassignment
    z = 10.5;
    if (z != 10.5)
        return 3;

    // Verify float-specific precision (not accidentally widened to f64)
    // 16777217 is 2^24 + 1, not exactly representable in f32
    // In f32: 16777216.0, in f64: 16777217.0
    float big = 16777217.0;
    if (big == 16777217.0)
        return 4;  // Would mean it's using f64 precision

    return 42;
}
