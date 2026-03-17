// EXPECTED: 10
// EXPECTED: 20
struct Point {
    int x;
    int y;
}

int main() {
    Point p;
    p.x = 10;
    p.y = 20;
    __writeln(p.x);
    __writeln(p.y);
    return 0;
}
