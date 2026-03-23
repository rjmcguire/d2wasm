// STATUS: maybeLater — super not implemented
// EXPECTED: 10
// EXPECTED: 20
class Base {
    int x;

    this(int x) {
        this.x = x;
    }
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
    __writeln(d.x);
    __writeln(d.y);
    return 0;
}
