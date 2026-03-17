// EXPECTED: 10
// EXPECTED: 7
T max(T)(T a, T b) {
    return a > b ? a : b;
}

int main() {
    __writeln(max!int(5, 10));
    __writeln(max!int(7, 3));
    return 0;
}
