// EXPECTED: 2
// EXPECTED: 4
// EXPECTED: 6
int main() {
    int[3] a = [1, 2, 3];
    for (int i = 0; i < 3; i++) a[i] *= 2;
    foreach (v; a) __writeln(v);
    return 0;
}
