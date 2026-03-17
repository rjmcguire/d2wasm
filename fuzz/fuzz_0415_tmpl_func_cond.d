// EXPECTED: 5
T myMax(T)(T a, T b) if (__traits(isArithmetic, T)) {
    return a > b ? a : b;
}

int main() {
    __writeln(myMax(3, 5));
    return 0;
}
