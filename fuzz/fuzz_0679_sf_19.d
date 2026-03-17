// EXPECTED: 19
struct S { int v; }

int main() {
    auto s = S(19);
    __writeln(s.v);
    return 0;
}
