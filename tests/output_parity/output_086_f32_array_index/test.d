// Output Parity Test: float (f32) array index assignment and read
// Verifies arr[i] = float_val and arr[i] read use correct 4-byte f32 ops

int main() {
    float[4] arr = [1.0, 2.0, 3.0, 4.0];

    // Basic read
    if (arr[0] != 1.0) return 1;
    if (arr[3] != 4.0) return 2;

    // Index write
    arr[1] = 10.5;
    if (arr[1] != 10.5) return 3;

    // Verify adjacent elements not corrupted (would happen if 8-byte f64 store used)
    if (arr[0] != 1.0) return 4;
    if (arr[2] != 3.0) return 5;

    // Write to last element, verify no out-of-bounds corruption
    arr[3] = 20.5;
    if (arr[3] != 20.5) return 6;
    if (arr[2] != 3.0) return 7;

    // Sum all elements: 1.0 + 10.5 + 3.0 + 20.5 = 35.0
    float sum = arr[0] + arr[1] + arr[2] + arr[3];
    if (sum != 35.0) return 8;

    // Loop-based index access
    float total = 0.0;
    for (int i = 0; i < 4; i++) {
        total = total + arr[i];
    }
    if (total != 35.0) return 9;

    return 42;
}
