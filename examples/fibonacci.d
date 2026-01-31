/**
 * Fibonacci sequence calculator
 * 
 * This is a simple example of recursive function implementation
 * that demonstrates basic D language features supported by the compiler.
 */

int fibonacci(int n) {
    if (n <= 1) {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
}

int main() {
    return fibonacci(10);
}