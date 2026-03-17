// EXPECTED: 15
int add(int a, int b) {
    return a + b;
}

int main() {
    __writeln(add(2 + 3, 4 + 6));
    return 0;
}
