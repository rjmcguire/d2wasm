// The integer crosses the host C ABI twice: the JIT entry of printValue,
// and the host call inside __writeln. Both must see 42.
int printValue(int x) {
    __writeln(x);
    return x + 1;
}

enum result = printValue(42);

int main() {
    return result;
}
