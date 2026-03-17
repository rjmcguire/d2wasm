// EXPECTED: 6
// EXPECTED: 8
struct P { int x; int y; }

P scale(P p, int f) {
    return P(p.x * f, p.y * f);
}

int main() {
    auto p = scale(P(3, 4), 2);
    __writeln(p.x);
    __writeln(p.y);
    return 0;
}
