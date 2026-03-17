// EXPECTED: 26
int main() {
    int a = 3;
    int b = 4;
    int c = 5;
    __writeln(a * b + b * c - a + b);
    return 0;
}
