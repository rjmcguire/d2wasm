// EXPECTED: 42
class Foo {
    int value;

    this(int v) {
        value = v;
    }

    int get() {
        return value;
    }
}

int main() {
    auto f = new Foo(42);
    __writeln(f.get());
    return 0;
}
