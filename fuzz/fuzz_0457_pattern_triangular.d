// STATUS: bug — compile error
// EXPECTED: 55
int main() {
    int n = 10;
    __writeln(n * (n + 1) / 2);
    return 0;
}
