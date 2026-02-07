/**
 * Milestone 145: WASM CTFE stack trace
 *
 * Tests that CTFE runtime errors include call stack traces.
 * This file contains a nested function call that will trigger
 * a division by zero error. The error message should include
 * the call stack.
 */

int divByZero(int a, int b) {
    return a / b;  // This will trap when b=0
}

int middle(int x) {
    return divByZero(x, 0);  // Pass 0 as divisor
}

int outer() {
    return middle(42);
}

// Manifest constant triggers CTFE
enum result = outer();

// Entry point (never reached - compile fails at manifest constant)
int test() {
    return result;
}
