// EXPECTED: 120
int main() {
    int[5] a = [1, 2, 3, 4, 5];
    int p = 1;
    foreach (v; a) p *= v;
    __writeln(p);
    return 0;
}
