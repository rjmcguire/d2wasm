// EXPECTED: 125
T cube(T)(T x) { return x * x * x; }

int main() {
    __writeln(cube!int(5));
    return 0;
}
