// EXPECTED: 10
@safe int double_(int x) {
    return x * 2;
}

int main() {
    __writeln(double_(5));
    return 0;
}
