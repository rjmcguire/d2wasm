int add(int a, int b) {
    return a + b;
}

// This should be evaluated at compile time
enum VALUE = add(2, 3);

// Export the value for testing
int getValue() {
    return VALUE;
}
