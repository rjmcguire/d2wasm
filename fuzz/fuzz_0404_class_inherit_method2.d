// EXPECTED: 20
class Base {
    int x;
    this(int x) { this.x = x; }
    int doubled() { return x * 2; }
}

class Child : Base {
    this(int x) { super(x); }
}

int main() {
    auto c = new Child(10);
    __writeln(c.doubled());
    return 0;
}
