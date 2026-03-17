// EXPECTED: 16
struct S { int v; }

int main() {
    auto s = S(16);
    __writeln(s.v);
    return 0;
}
