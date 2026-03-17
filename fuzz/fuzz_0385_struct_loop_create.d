// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 4
// EXPECTED: 9
struct S { int v; int sq() { return v * v; } }

int main() {
    for (int i = 0; i < 4; i++) {
        auto s = S(i);
        __writeln(s.sq());
    }
    return 0;
}
