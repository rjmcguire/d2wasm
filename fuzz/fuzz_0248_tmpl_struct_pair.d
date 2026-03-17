// EXPECTED: 1
// EXPECTED: 2
struct Pair(T, U) {
    T first;
    U second;
}

int main() {
    auto p = Pair!(int, int)(1, 2);
    __writeln(p.first);
    __writeln(p.second);
    return 0;
}
