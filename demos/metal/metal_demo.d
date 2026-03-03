// Metal Render Demo — D computes geometry, Metal renders it
//
// Generates a rainbow color wheel (triangle fan) and passes
// vertices to Metal via extern(C) FFI.

extern(C) int metal_init(int w, int h);
extern(C) void metal_add_vertex(float x, float y, float r, float g, float b, float a);
extern(C) void metal_render_and_run();

// Taylor-series sin/cos — good enough for generating geometry
double sin_approx(double x) {
    // Normalize x to [-pi, pi]
    double pi = 3.14159265;
    double two_pi = 6.28318530;

    // Reduce to [-pi, pi] range
    while (x > pi) x = x - two_pi;
    while (x < 0.0 - pi) x = x + two_pi;

    // x - x^3/6 + x^5/120 - x^7/5040
    double x2 = x * x;
    double x3 = x2 * x;
    double x5 = x3 * x2;
    double x7 = x5 * x2;
    return x - x3 / 6.0 + x5 / 120.0 - x7 / 5040.0;
}

double cos_approx(double x) {
    return sin_approx(x + 1.5707963);
}

int main() {
    if (metal_init(800, 600) == 0) {
        return 1;
    }

    // Generate a rainbow color wheel from triangle fan
    int segments = 64;
    double two_pi = 6.28318530;

    int i = 0;
    while (i < segments) {
        double fi = cast(double) i;
        double fi1 = cast(double)(i + 1);
        double a1 = fi * two_pi / cast(double) segments;
        double a2 = fi1 * two_pi / cast(double) segments;

        // Rainbow color from angle (phase-shifted sine waves)
        double r = sin_approx(a1) * 0.5 + 0.5;
        double g = sin_approx(a1 + 2.094) * 0.5 + 0.5;
        double b = sin_approx(a1 + 4.189) * 0.5 + 0.5;

        // Center vertex (dark)
        metal_add_vertex(cast(float) 0.0, cast(float) 0.0,
                         cast(float) 0.1, cast(float) 0.1, cast(float) 0.1, cast(float) 1.0);

        // Two outer vertices (rainbow colored)
        metal_add_vertex(cast(float)(cos_approx(a1) * 0.8), cast(float)(sin_approx(a1) * 0.8),
                         cast(float) r, cast(float) g, cast(float) b, cast(float) 1.0);
        metal_add_vertex(cast(float)(cos_approx(a2) * 0.8), cast(float)(sin_approx(a2) * 0.8),
                         cast(float) r, cast(float) g, cast(float) b, cast(float) 1.0);

        i = i + 1;
    }

    metal_render_and_run();
    return 0;
}
