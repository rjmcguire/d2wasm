// EXPECTED: 5
struct S { int v; }

int main() {
    auto s = S(5);
    __writeln(s.v);
    return 0;
}
