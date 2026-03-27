// Output Parity Test: float (f32) slice append
// Verifies ~= on float[] uses correct 4-byte f32 store/load (not 8-byte f64)
// This is the critical test — emitSliceAppend scratch area hardcodes f64 ops

int main() {
    float[] arr;

    // Single append
    arr ~= 1.5;
    if (arr[0] != 1.5) return 1;

    // Multiple appends — each element must be 4 bytes apart
    arr ~= 2.5;
    arr ~= 3.5;

    if (arr[0] != 1.5) return 2;
    if (arr[1] != 2.5) return 3;
    if (arr[2] != 3.5) return 4;

    // Verify length
    if (arr.length != 3) return 5;

    // Append enough to trigger reallocation (capacity starts at 4)
    arr ~= 4.5;
    arr ~= 5.5;  // This should trigger grow

    if (arr[0] != 1.5) return 6;
    if (arr[1] != 2.5) return 7;
    if (arr[2] != 3.5) return 8;
    if (arr[3] != 4.5) return 9;
    if (arr[4] != 5.5) return 10;

    // Sum all: 1.5 + 2.5 + 3.5 + 4.5 + 5.5 = 17.5
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        sum = sum + arr[i];
    }
    // 17.5 truncated to int = 17, plus 25 = 42
    int result = cast(int)sum + 25;
    return result;
}
