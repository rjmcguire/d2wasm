/**
 * Simple D program for testing the Phase 2 compiler
 * Tests basic arithmetic and function calls
 */

// Simple addition function
int add(int a, int b) {
    return a + b;
}

// Fibonacci function (recursive)
int fibonacci(int n) {
    if (n <= 1) {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
}

// Main function
int main() {
    int x = 5;
    int y = 10;
    int sum = add(x, y);
    
    // Calculate fibonacci of 7
    int fib = fibonacci(7);
    
    return fib;  // Should return 13
}