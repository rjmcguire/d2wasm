// EXPECTED: 5
struct Point {
    int x;
    int y;
}

int dist(Point p) {
    return p.x + p.y;
}

int main() {
    auto p = Point(2, 3);
    __writeln(dist(p));
    return 0;
}
