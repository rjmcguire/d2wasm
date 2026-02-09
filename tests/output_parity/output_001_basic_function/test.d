// Output Parity Test: Basic function
// All output backends should produce the same runtime result

int add(int a, int b) {
    return a + b;
}

int main() {
    return add(17, 25);  // 42
}
