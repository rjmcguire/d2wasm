// EXPECTED: 15
struct S { int v; }

int main() {
    auto s = S(15);
    __writeln(s.v);
    return 0;
}
