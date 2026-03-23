// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 10
class Num {
    int v;
    this(int v) { this.v = v; }
    int get() { return v; }
}

Num makeNum(int x) { return new Num(x); }

int main() {
    auto n = makeNum(10);
    __writeln(n.get());
    return 0;
}
