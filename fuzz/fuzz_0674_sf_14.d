// EXPECTED: 14
struct S { int v; }

int main() {
    auto s = S(14);
    __writeln(s.v);
    return 0;
}
