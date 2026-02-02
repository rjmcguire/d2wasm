// Test: struct parameter is a copy, modifications don't affect original
struct Point {
    int x;
    int y;
}

void mutate(Point p) {
    p.x = 999;  // Mutate the copy
}

int main() {
    Point p = Point(42, 0);
    mutate(p);
    return p.x;  // Should still be 42
}
