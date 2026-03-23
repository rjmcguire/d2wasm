// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: 1
// EXPECTED: 0
struct Foo {
    int x;
    int getX() { return x; }
}

int main() {
    static if (__traits(hasMember, Foo, "getX")) __writeln(1);
    else __writeln(0);
    static if (__traits(hasMember, Foo, "getY")) __writeln(1);
    else __writeln(0);
    return 0;
}
