// EXPECTED: 10
T identity(T)(T x) {
    return x;
}

int main() {
    __writeln(identity!int(10));
    return 0;
}
