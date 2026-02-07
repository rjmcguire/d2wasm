/**
 * Milestone 143: WASM call stack buffer reservation
 *
 * Tests that linear memory reserves space for call stack tracking.
 * Memory layout (2KB reserved):
 *   0-3:      depth (u32)
 *   4-7:      maxDepth (u32) = 64
 *   8-1543:   frames[64] (24 bytes each)
 *   1544-2047: String pool
 *   2048+:    Data section, heap
 */

// Simple function to verify compilation still works
int add(int a, int b) {
    return a + b;
}

// Nested calls to verify stack tracking region doesn't break normal operation
int outer(int x) {
    return inner(x) + 1;
}

int inner(int x) {
    return x * 2;
}

// Entry point for test
int test() {
    // Basic arithmetic
    int sum = add(10, 20);
    if (sum != 30) return 1;
    
    // Nested calls
    int result = outer(5);
    if (result != 11) return 2;  // inner(5) = 10, outer = 10 + 1 = 11
    
    return 0;
}
