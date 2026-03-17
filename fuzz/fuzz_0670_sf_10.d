// EXPECTED: 10
struct S { int v; }

int main() {
    auto s = S(10);
    __writeln(s.v);
    return 0;
}
