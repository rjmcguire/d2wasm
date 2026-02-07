/**
 * Milestone 144: WASM call stack push/pop
 *
 * Tests that call stack tracking opcodes are emitted at function entry/exit.
 * This test just verifies the opcodes don't break normal execution.
 * Stack trace reading is tested in milestone 145.
 */

// Simple recursive function to exercise stack push/pop
int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

// Nested function calls
int level3(int x) {
    return x * 2;
}

int level2(int x) {
    return level3(x) + 1;
}

int level1(int x) {
    return level2(x) + 10;
}

// Entry point
int test() {
    // Test recursive calls
    int f10 = fib(10);
    if (f10 != 55) return 1;
    
    // Test nested calls
    int result = level1(5);
    if (result != 21) return 2;  // level3(5)=10, level2=11, level1=21
    
    return 0;
}
