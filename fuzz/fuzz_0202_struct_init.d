// EXPECTED: 3
// EXPECTED: 4
struct Point {
    int x;
    int y;
}

int main() {
    auto p = Point(3, 4);
    __writeln(p.x);
    __writeln(p.y);
    return 0;
}
