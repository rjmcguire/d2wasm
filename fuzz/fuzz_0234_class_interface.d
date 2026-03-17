// EXPECTED: 42
interface Valuable {
    int getValue();
}

class MyVal : Valuable {
    int x;
    this(int x) { this.x = x; }
    int getValue() { return x; }
}

int main() {
    auto v = new MyVal(42);
    __writeln(v.getValue());
    return 0;
}
