// STATUS: bug — compile error
// EXPECTED: 10
// EXPECTED: 20
struct Point {
    int x;
    int y;

    this(int val) {
        this(val, val * 2);
    }

    this(int x, int y) {
        this.x = x;
        this.y = y;
    }
}

int main() {
    auto p = Point(10);
    __writeln(p.x);
    __writeln(p.y);
    return 0;
}
