// STATUS: bug — wrong output
// EXPECTED: 120
int a(int x) { return x + 1; }
int b(int x) { return x * 2; }
int c(int x) { return x + 10; }

int main() {
    __writeln(c(b(a(b(c(a(1)))))));
    return 0;
}
