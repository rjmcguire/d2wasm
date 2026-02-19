struct Point {
    int x;
    int y;
}

void setPoint(Point* p, int x, int y) {
    p.x = x;
    p.y = y;
}

int main() {
    // Test 1: basic pointer + auto-deref
    Point p = Point(10, 20);
    Point* ptr = &p;
    int r1 = ptr.x + ptr.y;  // expect 30

    // Test 2: pointer as function parameter
    Point q;
    setPoint(&q, 5, 15);
    int r2 = q.x + q.y;  // expect 20

    // Test 3: emplace
    Point r;
    emplace(&r, 3, 7);
    int r3 = r.x + r.y;  // expect 10

    // Test 4: pointer member assignment
    Point s;
    Point* sp = &s;
    sp.x = 4;
    sp.y = 6;
    int r4 = s.x + s.y;  // expect 10

    return r1 + r2 + r3 + r4;  // expect 70
}
