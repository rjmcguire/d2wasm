// EXPECTED: 10
// EXPECTED: 20
T doubleVal(T)(T x) {
    return x + x;
}

int main() {
    __writeln(doubleVal!int(5));
    __writeln(doubleVal!int(10));
    return 0;
}
