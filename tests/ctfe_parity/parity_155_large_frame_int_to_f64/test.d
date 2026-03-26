// Test: cast(double) int at high stack offsets after large struct

struct BigBuffer {
    int[4096] data;
    int len;
}

int main() {
    BigBuffer buf;
    buf.len = 0;

    int w = 1024;
    int h = 768;
    double dw = cast(double) w;
    double dh = cast(double) h;

    // If the int→f64 cast works, dw should be 1024.0
    if (dw < 1023.0) return 1;
    if (dw > 1025.0) return 2;
    if (dh < 767.0) return 3;
    if (dh > 769.0) return 4;

    return 42;
}
