// STATUS: bug — wrong output
// EXPECTED: 5
struct Inner {
    int val;
}

struct Outer {
    Inner inner;
    int extra;
}

int main() {
    Inner i = Inner(5);
    Outer o;
    o.inner = i;
    o.extra = 10;
    __writeln(o.inner.val);
    return 0;
}
