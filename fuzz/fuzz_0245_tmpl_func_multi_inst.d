// STATUS: bug — compile error
// EXPECTED: 5
// EXPECTED: 5000000000
T identity(T)(T x) {
    return x;
}

int main() {
    __writeln(identity!int(5));
    __writeln(identity!long(5000000000));
    return 0;
}
