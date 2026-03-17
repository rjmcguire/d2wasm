// EXPECTED: 5
// EXPECTED: 4
int main() {
    int[5] a = [1, 2, 3, 4, 5];
    __writeln(a[$ - 1]);
    __writeln(a[$ - 2]);
    return 0;
}
