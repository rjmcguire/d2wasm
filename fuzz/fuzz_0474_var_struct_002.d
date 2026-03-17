// EXPECTED: 20
struct R { int w; int h; int area() { return w * h; } }

int main() {
    __writeln(R(4, 5).area());
    return 0;
}
