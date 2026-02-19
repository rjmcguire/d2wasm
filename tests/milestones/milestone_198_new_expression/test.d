struct Point {
    int x;
    int y;
}

Point* makePoint(int x, int y) @gc(heap) {
    return new Point(x, y);
}

int main() @gc(heap) {
    // Test 1: basic new
    Point* p = new Point(3, 7);
    int r1 = p.x + p.y;  // expect 10

    // Test 2: new with zero args (zero-init)
    Point* q = new Point();
    int r2 = q.x + q.y;  // expect 0

    // Test 3: transitive @gc — calling a @gc function
    Point* r = makePoint(5, 15);
    int r3 = r.x + r.y;  // expect 20

    return r1 + r2 + r3;  // expect 30
}
