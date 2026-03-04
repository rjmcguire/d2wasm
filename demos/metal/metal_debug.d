// Debug test — 2 hardcoded triangles, no loop, no sin/cos
// If both render, the FFI pipeline works and issue is in the loop.

extern(C) int metal_init(int w, int h);
extern(C) void metal_add_vertex(double x, double y, double r, double g, double b, double a);
extern(C) void metal_render_and_run();

int main() {
    if (metal_init(800, 600) == 0) {
        return 1;
    }

    // Triangle 1: red, center-left
    metal_add_vertex(-0.6, -0.4, 1.0, 0.0, 0.0, 1.0);
    metal_add_vertex(-0.2, -0.4, 1.0, 0.0, 0.0, 1.0);
    metal_add_vertex(-0.4,  0.2, 1.0, 0.0, 0.0, 1.0);

    // Triangle 2: blue, center-right
    metal_add_vertex( 0.2, -0.4, 0.0, 0.0, 1.0, 1.0);
    metal_add_vertex( 0.6, -0.4, 0.0, 0.0, 1.0, 1.0);
    metal_add_vertex( 0.4,  0.2, 0.0, 0.0, 1.0, 1.0);

    metal_render_and_run();
    return 0;
}
