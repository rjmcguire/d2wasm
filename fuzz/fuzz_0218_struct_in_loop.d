// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 4
// EXPECTED: 9
int main() {
    struct Sq {
        int val;
        int sq() { return val * val; }
    }
    for (int i = 0; i < 4; i++) {
        auto s = Sq(i);
        __writeln(s.sq());
    }
    return 0;
}
