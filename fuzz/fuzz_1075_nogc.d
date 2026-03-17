// EXPECTED: 7
@nogc int add(int a, int b) {
    return a + b;
}

int main() {
    __writeln(add(3, 4));
    return 0;
}
