// Output Parity Test: float (f32) static array
// Verifies float[N] init, element access, write, and neighbor corruption checks

int main() {
    float[4] arr = [1.5, 2.5, 3.5, 4.5];

    // Verify init
    if (arr[0] != 1.5) return 1;
    if (arr[1] != 2.5) return 2;
    if (arr[2] != 3.5) return 3;
    if (arr[3] != 4.5) return 4;

    // Element write — must use 4-byte f32 store, not 8-byte f64
    arr[1] = 99.0;
    if (arr[1] != 99.0) return 5;

    // Verify adjacent elements not corrupted (would be if 8-byte store used)
    if (arr[0] != 1.5) return 6;
    if (arr[2] != 3.5) return 7;

    // Write last element
    arr[3] = 20.5;
    if (arr[3] != 20.5) return 8;
    if (arr[2] != 3.5) return 9;

    // Loop-based sum: 1.5 + 99.0 + 3.5 + 20.5 = 124.5
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        sum = sum + arr[i];
    }
    // 124.5 truncated to int is 124; 124 - 82 = 42
    int result = cast(int)sum - 82;
    return result;
}
