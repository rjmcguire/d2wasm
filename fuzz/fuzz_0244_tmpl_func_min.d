// STATUS: maybeLater — ternary not parsed
// EXPECTED: 3
// EXPECTED: 1
T min(T)(T a, T b) {
    return a < b ? a : b;
}

int main() {
    __writeln(min!int(3, 5));
    __writeln(min!int(1, 9));
    return 0;
}
