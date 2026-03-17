// EXPECTED: 1
struct S { int v; }

int main() {
    auto s = S(1);
    __writeln(s.v);
    return 0;
}
