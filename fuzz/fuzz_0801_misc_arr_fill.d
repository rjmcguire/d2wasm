// EXPECTED: 10
int main() {
    int[10] a;
    for (int i = 0; i < 10; i++) a[i] = i;
    __writeln(a[5] + a[5]);
    return 0;
}
