// EXPECTED: created
// EXPECTED: destroyed
struct Foo {
    ~this() {
        __writeln("destroyed");
    }
}

int main() {
    {
        Foo f;
        __writeln("created");
    }
    return 0;
}
