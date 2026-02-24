struct Point {
    int x;
    int y;
}

// Test 1: Stack-promoted new — pointer doesn't escape
int testStackPromoted() @gc(heap) {
    Point* p = new Point(3, 7);
    return p.x + p.y;  // expect 10
}

// Test 2: Stack-promoted new with field writes
int testStackPromotedWrite() @gc(heap) {
    Point* p = new Point(0, 0);
    p.x = 100;
    p.y = 200;
    return p.x + p.y;  // expect 300
}

// Test 3: Heap new — pointer escapes via return (must stay on heap)
Point* testHeapReturn(int x, int y) @gc(heap) {
    return new Point(x, y);
}

// Test 4: Heap new — pointer escapes via function call (conservative)
void consume(Point* p) @gc(heap) {}
int testEscapeViaCall() @gc(heap) {
    Point* p = new Point(1, 2);
    consume(p);
    return p.x + p.y;  // expect 3
}

int main() @gc(heap) {
    int r1 = testStackPromoted();
    int r2 = testStackPromotedWrite();
    Point* r3 = testHeapReturn(5, 15);
    int r3val = r3.x + r3.y;
    int r4 = testEscapeViaCall();
    return r1 + r2 + r3val + r4;  // 10 + 300 + 20 + 3 = 333
}
