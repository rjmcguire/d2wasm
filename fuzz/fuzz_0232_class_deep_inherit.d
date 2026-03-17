// EXPECTED: 30
class A {
    int x;
    this(int x) { this.x = x; }
}

class B : A {
    int y;
    this(int x, int y) { super(x); this.y = y; }
}

class C : B {
    int z;
    this(int x, int y, int z) { super(x, y); this.z = z; }
}

int main() {
    auto c = new C(10, 20, 30);
    __writeln(c.z);
    return 0;
}
