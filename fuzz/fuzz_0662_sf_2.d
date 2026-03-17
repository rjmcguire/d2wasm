// EXPECTED: 2
struct S { int v; }

int main() {
    auto s = S(2);
    __writeln(s.v);
    return 0;
}
