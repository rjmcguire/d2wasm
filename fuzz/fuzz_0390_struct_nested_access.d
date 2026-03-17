// EXPECTED: 42
struct Inner { int v; }
struct Outer { Inner i; }

int main() {
    Outer o;
    o.i = Inner(42);
    __writeln(o.i.v);
    return 0;
}
