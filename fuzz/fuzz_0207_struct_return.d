// EXPECTED: 10
// EXPECTED: 20
struct Point {
    int x;
    int y;
}

Point makePoint(int x, int y) {
    return Point(x, y);
}

int main() {
    auto p = makePoint(10, 20);
    __writeln(p.x);
    __writeln(p.y);
    return 0;
}
