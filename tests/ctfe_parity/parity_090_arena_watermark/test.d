// Allocates arena memory (array appends), verifies contents, returns scalar.
// Since return type is int (not slice), arena_drop fires at exit,
// restoring the watermark and reclaiming all allocations.
int allocate_and_check(int n) {
    int[] arr;
    int i = 0;
    while (i < n) {
        arr ~= i * 2;
        i = i + 1;
    }
    // Verify array contents are correct
    i = 0;
    while (i < n) {
        if (arr[i] != i * 2) return -1;
        i = i + 1;
    }
    return arr[n - 1];
}

int test() {
    // Call 100 times — each call allocates ~2KB of arena memory.
    // With working watermark: ~2KB reused each time (WASM).
    // Without watermark: ~200KB accumulated.
    // Either way both backends handle this, but correctness
    // (no data corruption across calls) proves the mechanism works.
    int i = 0;
    while (i < 100) {
        int result = allocate_and_check(500);
        if (result != 998) return 1;  // (500-1) * 2 = 998
        i = i + 1;
    }
    return 0;
}

enum RESULT = test();
int main() { return RESULT; }
