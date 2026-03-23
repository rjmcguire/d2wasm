// STATUS: bug — compile error
// EXPECTED: 6
// EXPECTED: 60
int compute(int a, int b = 2, int c = 3) {
    return a * b * c;
}

int main() {
    __writeln(compute(1));
    __writeln(compute(2, 5, 6));
    return 0;
}
