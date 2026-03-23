// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 15
class Calc {
    int base;
    this(int b) { base = b; }
    int addTo(int x) { return base + x; }
}

int main() {
    auto c = new Calc(10);
    __writeln(c.addTo(5));
    return 0;
}
