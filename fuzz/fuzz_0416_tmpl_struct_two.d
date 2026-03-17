// EXPECTED: 10
// EXPECTED: 20
struct Pair(T, U) { T a; U b; }

int main() {
    auto p = Pair!(int, int)(10, 20);
    __writeln(p.a);
    __writeln(p.b);
    return 0;
}
