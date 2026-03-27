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

    // Verify multiple reassignments
    float w = 1.0;
    w = 2.0;
    w = 3.0;
    if (w != 3.0)
        return 4;

    // Verify float computed from int cast
    int n = 7;
    float f = cast(float)n;
    if (f != 7.0)
        return 5;

    return 42;
}
