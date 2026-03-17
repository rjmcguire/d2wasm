// EXPECTED: 20
struct S { int v; }

int main() {
    auto s = S(20);
    __writeln(s.v);
    return 0;
}
