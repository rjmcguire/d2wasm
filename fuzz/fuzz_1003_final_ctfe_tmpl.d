// EXPECTED: 50
T doubleVal(T)(T x) {
    return x + x;
}

enum result = doubleVal!int(25);

int main() {
    __writeln(result);
    return 0;
}
