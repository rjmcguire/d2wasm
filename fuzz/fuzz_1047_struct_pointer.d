// EXPECTED: 10
struct Point {
    int x;
    int y;
}

int main() {
    Point p = Point(10, 20);
    Point* pp = &p;
    __writeln(pp.x);
    return 0;
}
