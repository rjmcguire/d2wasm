// Test struct type alias: alias P = Point;

struct Point {
    int x;
    int y;
}

alias P = Point;

int main() {
    P p = Point(10, 32);
    return p.x + p.y;  // 42
}
