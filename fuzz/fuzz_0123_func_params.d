// EXPECTED: 8
// EXPECTED: 15
int add(int a, int b) {
    return a + b;
}

int main() {
    __writeln(add(3, 5));
    __writeln(add(7, 8));
    return 0;
}
