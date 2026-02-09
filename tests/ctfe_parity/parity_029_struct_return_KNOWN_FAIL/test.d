struct Pair {
    int a;
    int b;
}

Pair makePair(int x, int y) {
    return Pair(x, y);
}

int test() {
    Pair p = makePair(15, 27);
    return p.a + p.b;  // 42
}

enum RESULT = test();
int main() { return RESULT; }
