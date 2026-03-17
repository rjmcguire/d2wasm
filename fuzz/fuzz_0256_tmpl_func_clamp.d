// EXPECTED: 5
// EXPECTED: 0
// EXPECTED: 10
T clamp(T)(T val, T lo, T hi) {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

int main() {
    __writeln(clamp!int(5, 0, 10));
    __writeln(clamp!int(-5, 0, 10));
    __writeln(clamp!int(20, 0, 10));
    return 0;
}
