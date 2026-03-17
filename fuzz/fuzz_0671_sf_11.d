// EXPECTED: 11
struct S { int v; }

int main() {
    auto s = S(11);
    __writeln(s.v);
    return 0;
}
