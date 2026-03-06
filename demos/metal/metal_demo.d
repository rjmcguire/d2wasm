// Metal Render Demo — D computes geometry, Metal renders it
//
// Generates a rainbow color wheel (triangle fan) and passes
// vertices to Metal via extern(C) FFI. Handles mouse clicks
// to change background color.

extern(C) int metal_init(int w, int h);
extern(C) void metal_add_vertex(double x, double y, double r, double g, double b, double a);
extern(C) void metal_create_buffers();
extern(C) int metal_process_events();
extern(C) int metal_has_click();
extern(C) double metal_get_click_x();
extern(C) double metal_get_click_y();
extern(C) void metal_set_clear_color(double r, double g, double b);
extern(C) void metal_render_frame();

// Taylor-series sin/cos — good enough for generating geometry
double sin_approx(double x) {
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

void on_click(double x, double y) {
    // Map click position to a color
    double r = x * 0.5 + 0.5;
    double g = y * 0.5 + 0.5;
    double b = 1.0 - r;
    metal_set_clear_color(r, g, b);
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
        metal_add_vertex(0.0, 0.0, 0.1, 0.1, 0.1, 1.0);

        // Two outer vertices (rainbow colored)
        metal_add_vertex(cos_approx(a1) * 0.8, sin_approx(a1) * 0.8, r, g, b, 1.0);
        metal_add_vertex(cos_approx(a2) * 0.8, sin_approx(a2) * 0.8, r, g, b, 1.0);

        i = i + 1;
    }

    // Create Metal buffers and show window
    metal_create_buffers();

    // Game loop: poll events, handle clicks, render frames
    while (metal_process_events() != 0) {
        if (metal_has_click() != 0) {
            double cx = metal_get_click_x();
            double cy = metal_get_click_y();
            on_click(cx, cy);
        }
        metal_render_frame();
    }

    return 0;
}
