// EXPECTED: 15
int apply(int delegate(int) fn, int x) {
    return fn(x);
}

int main() {
    auto triple = delegate int(int x) { return x * 3; };
    __writeln(apply(triple, 5));
    return 0;
}
