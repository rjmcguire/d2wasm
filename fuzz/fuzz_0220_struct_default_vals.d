// EXPECTED: 0
// EXPECTED: 0
struct Point {
    int x;
    int y;
}

int main() {
    Point p;
    __writeln(p.x);
    __writeln(p.y);
    return 0;
}
