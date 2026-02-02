// Test: struct copy semantics (b = a creates independent copy)
struct Point {
    int x;
    int y;
}

int main() {
    Point a = Point(1, 2);
    Point b = a;  // Copy
    a.x = 99;     // Mutate original
    return b.x;   // Should still be 1
}
