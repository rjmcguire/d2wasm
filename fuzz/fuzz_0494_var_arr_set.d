// EXPECTED: 42
int main() {
    int[3] a = [0, 0, 0];
    a[1] = 42;
    __writeln(a[1]);
    return 0;
}
