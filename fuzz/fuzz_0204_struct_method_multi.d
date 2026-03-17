// EXPECTED: 12
// EXPECTED: 14
struct Rect {
    int w;
    int h;

    int area() {
        return w * h;
    }

    int perimeter() {
        return 2 * (w + h);
    }
}

int main() {
    auto r = Rect(3, 4);
    __writeln(r.area());
    __writeln(r.perimeter());
    return 0;
}
