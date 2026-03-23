// STATUS: bug — wrong output
// EXPECTED: 7
struct Point { int x; int y; }

Point add(Point a, Point b) {
    return Point(a.x + b.x, a.y + b.y);
}

int main() {
    auto p1 = Point(1, 2);
    auto p2 = Point(3, 4);
    auto p3 = add(p1, p2);
    __writeln(p3.x + p3.y - p3.x + 3);
    return 0;
}
