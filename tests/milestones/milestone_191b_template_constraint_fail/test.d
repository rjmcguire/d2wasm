struct Point {
    int x;
    int y;
}

T add(T)(T a, T b) if (__traits(isArithmetic, T)) {
    return a + b;
}

int main() {
    auto p = add(Point(1, 2), Point(3, 4));  // Point is not arithmetic
    return p.x;
}
