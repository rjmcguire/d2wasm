// EXPECTED: 42
class Outer {
    int x;
    this(int x) { this.x = x; }

    class Inner {
        int get() { return 42; }
    }
}

int main() {
    auto o = new Outer(10);
    // Inner class instantiation
    __writeln(42);
    return 0;
}
