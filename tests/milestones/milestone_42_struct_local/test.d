// Test: local struct variable (requires shadow stack)
struct Point {
    int x;
    int y;
}

int main() {
    Point p = Point(10, 20);
    return p.x;  // 10
}
