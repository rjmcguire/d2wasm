// EXPECTED: 30
struct Rect {
    int w;
    int h;

    int area() {
        return w * h;
    }
}

int main() {
    auto r = Rect(5, 6);
    __writeln(r.area());
    return 0;
}
