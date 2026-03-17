// EXPECTED: 10
class Base {
    int val;
    this(int v) { val = v; }
    int doubled() { return val * 2; }
}

class Child : Base {
    this(int v) { super(v); }
}

int main() {
    auto c = new Child(5);
    __writeln(c.doubled());
    return 0;
}
