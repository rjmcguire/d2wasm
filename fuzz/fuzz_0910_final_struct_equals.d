// EXPECTED: 1
// EXPECTED: 0
struct P { int x; int y; }

bool eq(P a, P b) { return a.x == b.x && a.y == b.y; }

int main() {
    if (eq(P(1,2), P(1,2))) __writeln(1); else __writeln(0);
    if (eq(P(1,2), P(3,4))) __writeln(1); else __writeln(0);
    return 0;
}
