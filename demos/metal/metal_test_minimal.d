extern(C) void metal_add_vertex(double x, double y, double r, double g, double b, double a);

double sin_approx(double x) {
    double x2 = x * x;
    return x - x2 / 6.0;
}

double cos_approx(double x) {
    return sin_approx(x + 1.5707963);
}

int main() {
    double a1 = 1.0;
    metal_add_vertex(cos_approx(a1) * 0.8, sin_approx(a1) * 0.8, 0.5, 0.5, 0.5, 1.0);
    return 42;
}
