// EXPECTED: 25
struct S {
    int x;
    int sq() { return x * x; }
}

int main() {
    auto s = S(5);
    __writeln(s.sq());
    return 0;
}
