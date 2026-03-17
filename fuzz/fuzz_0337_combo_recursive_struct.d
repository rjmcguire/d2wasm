// EXPECTED: 6
struct Pair { int a; int b; }

int sumPair(Pair p) {
    return p.a + p.b;
}

int main() {
    auto p = Pair(1, 2);
    int total = sumPair(p) + sumPair(Pair(p.b, p.a));
    __writeln(total);
    return 0;
}
