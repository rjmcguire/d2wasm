// EXPECTED: 99
struct S { int x; }

int main() {
    S s = S(1);
    s.x = 99;
    __writeln(s.x);
    return 0;
}
