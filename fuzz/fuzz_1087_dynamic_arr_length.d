// EXPECTED: 0
// EXPECTED: 3
int main() {
    int[] a;
    __writeln(a.length);
    a ~= 1;
    a ~= 2;
    a ~= 3;
    __writeln(a.length);
    return 0;
}
