// EXPECTED: 30
T triple(T)(T x) {
    return x + x + x;
}

enum result = triple!int(10);

int main() {
    __writeln(result);
    return 0;
}
