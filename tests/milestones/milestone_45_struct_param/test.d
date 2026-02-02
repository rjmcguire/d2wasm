// Test: passing struct to function (pass-by-value via pointer-to-copy)
struct Point {
    int x;
    int y;
}

int getX(Point p) {
    return p.x;
}

int main() {
    Point p = Point(42, 7);
    return getX(p);  // 42
}
