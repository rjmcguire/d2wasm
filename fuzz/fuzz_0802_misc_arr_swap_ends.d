// EXPECTED: 5
// EXPECTED: 1
int main() {
    int[5] a = [1, 2, 3, 4, 5];
    int t = a[0]; a[0] = a[4]; a[4] = t;
    __writeln(a[0]);
    __writeln(a[4]);
    return 0;
}
