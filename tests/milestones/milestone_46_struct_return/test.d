// Test: returning struct from function (hidden return pointer)
struct Point {
    int x;
    int y;
}

Point makePoint(int x, int y) {
    Point p = Point(x, y);
    return p;
}

int main() {
    Point p = makePoint(3, 4);
    return p.x + p.y;  // 7
}
