// STATUS: bug — compile error
// EXPECTED: 10
struct Outer(T) {
    struct Inner {
        T val;
    }
    Inner make(T v) {
        return Inner(v);
    }
}

int main() {
    Outer!int o;
    auto inner = o.make(10);
    __writeln(inner.val);
    return 0;
}
