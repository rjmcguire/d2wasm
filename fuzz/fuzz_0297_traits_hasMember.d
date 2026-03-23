// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: 1
// EXPECTED: 0
struct Foo {
    int x;
}

int main() {
    static if (__traits(hasMember, Foo, "x")) __writeln(1);
    else __writeln(0);
    static if (__traits(hasMember, Foo, "y")) __writeln(1);
    else __writeln(0);
    return 0;
}
