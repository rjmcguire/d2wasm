// Test: writing to struct field
struct Point {
    int x;
    int y;
}

int main() {
    Point p = Point(0, 0);
    p.x = 42;
    return p.x;  // 42
}
