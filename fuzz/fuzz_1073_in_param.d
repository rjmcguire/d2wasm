// EXPECTED: 42
int read(in int x) {
    return x;
}

int main() {
    __writeln(read(42));
    return 0;
}
