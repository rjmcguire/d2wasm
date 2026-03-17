// EXPECTED: 9
struct S { int v; }

int main() {
    auto s = S(9);
    __writeln(s.v);
    return 0;
}
