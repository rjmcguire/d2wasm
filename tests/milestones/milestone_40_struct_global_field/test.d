// Test: global struct with field access
struct Point {
    int x;
    int y;
}

immutable Point P = Point(42, 10);

int main() {
    return P.x;  // 42
}
