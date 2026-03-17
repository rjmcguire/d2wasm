// EXPECTED: 5
// EXPECTED: 10
struct Point {
    int x = 5;
    int y = 10;
}

int main() {
    Point p;
    __writeln(p.x);
    __writeln(p.y);
    return 0;
}
