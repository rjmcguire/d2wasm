// EXPECTED: 7
struct P { int x; int y; }

int main() {
    auto p = P(3, 4);
    __writeln(p.x + p.y);
    return 0;
}
