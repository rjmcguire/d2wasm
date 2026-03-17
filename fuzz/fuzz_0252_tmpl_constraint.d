// EXPECTED: 15
T sum(T)(T a, T b) if (__traits(isArithmetic, T)) {
    return a + b;
}

int main() {
    __writeln(sum!int(7, 8));
    return 0;
}
