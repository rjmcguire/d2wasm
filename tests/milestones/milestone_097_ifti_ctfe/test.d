// Test IFTI with CTFE: enum M = max(3, 8) should deduce T=int

T max(T)(T a, T b) {
    if (a > b) return a;
    return b;
}

enum M = max(3, 8);

int result() {
    return M;
}
