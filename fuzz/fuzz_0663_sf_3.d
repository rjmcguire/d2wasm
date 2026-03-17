// EXPECTED: 3
struct S { int v; }

int main() {
    auto s = S(3);
    __writeln(s.v);
    return 0;
}
