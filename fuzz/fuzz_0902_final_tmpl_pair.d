// EXPECTED: 3
// EXPECTED: 4
struct Pair(T, U) { T a; U b; }

int main() {
    auto p = Pair!(int, int)(3, 4);
    __writeln(p.a);
    __writeln(p.b);
    return 0;
}
