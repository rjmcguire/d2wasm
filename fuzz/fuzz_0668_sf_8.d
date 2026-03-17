// EXPECTED: 8
struct S { int v; }

int main() {
    auto s = S(8);
    __writeln(s.v);
    return 0;
}
