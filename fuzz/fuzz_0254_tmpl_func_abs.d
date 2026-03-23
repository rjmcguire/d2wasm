// STATUS: maybeLater — ternary not parsed
// EXPECTED: 5
// EXPECTED: 5
T abs(T)(T x) {
    return x >= 0 ? x : -x;
}

int main() {
    __writeln(abs!int(5));
    __writeln(abs!int(-5));
    return 0;
}
