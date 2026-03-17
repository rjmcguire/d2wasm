// EXPECTED: 10
int main() {
    int[] a;
    for (int i = 0; i < 10; i++) a ~= i;
    __writeln(a.length);
    return 0;
}
