// STATUS: bug — compile error
// EXPECTED: 42
struct Foo {
    static int value() {
        return 42;
    }
}

int main() {
    __writeln(Foo.value());
    return 0;
}
