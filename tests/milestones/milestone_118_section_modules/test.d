// milestone_118: Section module extraction
// Verifies that the refactored section modules produce correct WASM output

int add(int a, int b) {
    return a + b;
}

int main() {
    return add(30, 12);  // 42
}
