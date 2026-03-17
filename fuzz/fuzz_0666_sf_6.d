// EXPECTED: 6
struct S { int v; }

int main() {
    auto s = S(6);
    __writeln(s.v);
    return 0;
}
