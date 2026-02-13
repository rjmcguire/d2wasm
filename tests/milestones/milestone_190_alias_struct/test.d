// Test struct type alias and alias chains

struct Point {
    int x;
    int y;
}

alias P = Point;
alias Q = P;  // alias chain: Q -> P -> Point

int main() {
    P p = Point(10, 20);
    Q q = Point(5, 7);
    return p.x + p.y + q.x + q.y;  // 10 + 20 + 5 + 7 = 42
}
