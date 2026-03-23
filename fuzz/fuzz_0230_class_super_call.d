// STATUS: maybeLater — super not implemented
// EXPECTED: base=10
// EXPECTED: derived=20
class Base {
    int x;
    this(int x) { this.x = x; }
    int getX() { return x; }
}

class Derived : Base {
    int y;
    this(int x, int y) {
        super(x);
        this.y = y;
    }
}

int main() {
    auto d = new Derived(10, 20);
    __writeln("base=" ~ __itos(d.getX()));
    __writeln("derived=" ~ __itos(d.y));
    return 0;
}
