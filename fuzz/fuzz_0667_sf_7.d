// EXPECTED: 7
struct S { int v; }

int main() {
    auto s = S(7);
    __writeln(s.v);
    return 0;
}
