// STATUS: maybeLater — null not implemented
// EXPECTED: null
// EXPECTED: not null
class Foo {
    int x;
    this(int x) { this.x = x; }
}

int main() {
    Foo f = null;
    if (f is null) __writeln("null");
    else __writeln("not null");
    f = new Foo(5);
    if (f is null) __writeln("null");
    else __writeln("not null");
    return 0;
}
