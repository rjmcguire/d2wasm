// STATUS: bug — compile error
// EXPECTED: 3
// EXPECTED: 6
int add(int a, int b) {
    return a + b;
}

int add(int a, int b, int c) {
    return a + b + c;
}

int main() {
    __writeln(add(1, 2));
    __writeln(add(1, 2, 3));
    return 0;
}
