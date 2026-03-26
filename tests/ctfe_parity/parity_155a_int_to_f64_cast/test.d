// Test: cast(double) int — basic int-to-f64 conversion

int main() {
    int w = 1024;
    double dw = cast(double) w;

    // If the int→f64 cast works, dw should be 1024.0
    if (dw < 1023.0) return 1;
    if (dw > 1025.0) return 2;

    return 42;
}
