// EXPECTED: 12
struct S { int v; }

int main() {
    auto s = S(12);
    __writeln(s.v);
    return 0;
}
