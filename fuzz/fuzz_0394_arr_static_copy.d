// STATUS: bug — compile error
// EXPECTED: 99
// EXPECTED: 1
int main() {
    int[3] a = [1, 2, 3];
    int[3] b = a;
    b[0] = 99;
    __writeln(b[0]);
    __writeln(a[0]);
    return 0;
}
