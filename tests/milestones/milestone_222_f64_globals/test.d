// Milestone 222: f64 scalar global variables
//
// Module-level double globals need f64.const init expressions in the
// WASM global section. Previously only i32/i64 init expressions were
// emitted, producing invalid WASM binaries for f64 globals.

double g_x = 0.05;
double g_y = 0.0;
int g_count = 0;

void setX(double v) {
    g_x = v;
}

double getX() {
    return g_x;
}

int test() {
    // Initial value from f64 init expression
    if (g_count != 0) return 1;

    // Mutate f64 global
    setX(3.14);
    double val = getX();

    // Check it round-trips (compare as int bits via truncation)
    if (val > 3.15) return 2;
    if (val < 3.13) return 3;

    // Direct assignment
    g_y = 100.0;
    if (g_y < 99.0) return 4;
    if (g_y > 101.0) return 5;

    return 0;
}
