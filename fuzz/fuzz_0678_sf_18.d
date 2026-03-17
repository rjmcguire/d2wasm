// EXPECTED: 18
struct S { int v; }

int main() {
    auto s = S(18);
    __writeln(s.v);
    return 0;
}
