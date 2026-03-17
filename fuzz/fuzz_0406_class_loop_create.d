// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
class Num {
    int v;
    this(int v) { this.v = v; }
}

int main() {
    for (int i = 0; i < 3; i++) {
        auto n = new Num(i);
        __writeln(n.v);
    }
    return 0;
}
