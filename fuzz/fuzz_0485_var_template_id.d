// EXPECTED: 99
T id(T)(T x) { return x; }

int main() {
    __writeln(id(99));
    return 0;
}
