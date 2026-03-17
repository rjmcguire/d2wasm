// EXPECTED: 13
struct S { int v; }

int main() {
    auto s = S(13);
    __writeln(s.v);
    return 0;
}
