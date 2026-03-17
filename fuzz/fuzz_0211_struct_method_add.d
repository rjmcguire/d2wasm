// EXPECTED: 4
// EXPECTED: 6
struct Point {
    int x;
    int y;

    Point add(Point other) {
        return Point(x + other.x, y + other.y);
    }
}

int main() {
    auto a = Point(1, 2);
    auto b = Point(3, 4);
    auto c = a.add(b);
    __writeln(c.x);
    __writeln(c.y);
    return 0;
}
