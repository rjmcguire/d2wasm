struct Pair {
    int a;
    int b;
}

// Escapes via return — must heap-allocate
Pair* escapeReturn(int x, int y) @gc(heap) {
    return new Pair(x, y);
}

// Escapes via function call — must heap-allocate
int readPair(Pair* p) @gc(heap) {
    return p.a + p.b;
}
int escapeViaCall() @gc(heap) {
    Pair* p = new Pair(11, 22);
    return readPair(p);  // 33
}

// Escapes via alias — assigned to another variable
int escapeViaAlias() @gc(heap) {
    Pair* p = new Pair(3, 4);
    Pair* q = p;
    return q.a + q.b;  // 7
}

int main() @gc(heap) {
    Pair* r1 = escapeReturn(10, 20);
    int v1 = r1.a + r1.b;       // 30
    int v2 = escapeViaCall();    // 33
    int v3 = escapeViaAlias();   // 7
    return v1 + v2 + v3;        // 30 + 33 + 7 = 70
}
