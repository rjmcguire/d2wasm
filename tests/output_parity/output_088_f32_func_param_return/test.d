// Output Parity Test: float (f32) function parameters and return values
// Verifies f32 is correctly passed and returned through function calls

float addFloats(float a, float b) {
    return a + b;
}

float mulFloat(float x, float y) {
    return x * y;
}

// Mixed params: int and float interleaved
float mixed(int n, float f, int m) {
    return f * cast(float)(n + m);
}

// Float return consumed by caller
int useFloat(float f) {
    if (f > 10.0)
        return 1;
    return 0;
}

int main() {
    // Basic f32 param + return
    float r1 = addFloats(1.5, 2.5);
    if (r1 != 4.0) return 1;

    // Chain f32 calls
    float r2 = mulFloat(addFloats(2.0, 3.0), 2.0);
    // (2.0 + 3.0) * 2.0 = 10.0
    if (r2 != 10.0) return 2;

    // Mixed int/float params
    float r3 = mixed(3, 2.5, 7);
    // 2.5 * (3 + 7) = 25.0
    if (r3 != 25.0) return 3;

    // Float return used in int context
    if (useFloat(5.0) != 0) return 4;
    if (useFloat(15.0) != 1) return 5;

    // f32 through multiple call layers
    float r4 = addFloats(mulFloat(1.5, 2.0), mulFloat(2.5, 2.0));
    // (1.5*2.0) + (2.5*2.0) = 3.0 + 5.0 = 8.0
    if (r4 != 8.0) return 6;

    return 42;
}
