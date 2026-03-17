// EXPECTED: 4
struct S { int v; }

int main() {
    auto s = S(4);
    __writeln(s.v);
    return 0;
}
