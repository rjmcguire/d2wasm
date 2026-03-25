// Test: struct with single double field
struct Wrapper {
    double val;
}

int main() {
    Wrapper w;
    w.val = 5.0;
    if (w.val > 3.0) return 42;
    return 1;
}
