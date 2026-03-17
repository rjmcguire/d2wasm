// EXPECTED: 25
// EXPECTED: 100
T square(T)(T x) {
    return x * x;
}

int main() {
    __writeln(square!int(5));
    __writeln(square!int(10));
    return 0;
}
