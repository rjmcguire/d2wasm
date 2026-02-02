// Test: struct .sizeof property
struct Point {
    int x;
    int y;
}

int main() {
    return Point.sizeof;  // 8 (two 4-byte ints)
}
