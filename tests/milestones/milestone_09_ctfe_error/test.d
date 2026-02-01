int divide(int a, int b) {
    return a / b;
}

// This should fail at compile time with a clear error
enum BAD = divide(10, 0);
