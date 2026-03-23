// STATUS: bug — wrong output
// EXPECTED: 42
int main() {
    int a = 2;
    int b = 3;
    int c = 4;
    int d = 5;
    __writeln(a * b * c + d * (a + b) - d - a - b);
    return 0;
}
