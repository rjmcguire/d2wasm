// EXPECTED: 10
// EXPECTED: 20
struct Point {
    int x;
    int y;
}

int main() {
    Point p = Point(10, 20);
    with (p) {
        __writeln(x);
        __writeln(y);
    }
    return 0;
}
