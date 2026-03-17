// EXPECTED: 5
T diff(T)(T a, T b) { return a > b ? a - b : b - a; }

int main() {
    __writeln(diff!int(3, 8));
    return 0;
}
