// EXPECTED: 17
struct S { int v; }

int main() {
    auto s = S(17);
    __writeln(s.v);
    return 0;
}
