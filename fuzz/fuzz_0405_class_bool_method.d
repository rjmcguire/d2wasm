// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 1
class BoolBox {
    bool val;
    this(bool v) { val = v; }
    bool get() { return val; }
}

int main() {
    auto b = new BoolBox(true);
    if (b.get()) __writeln(1); else __writeln(0);
    return 0;
}
