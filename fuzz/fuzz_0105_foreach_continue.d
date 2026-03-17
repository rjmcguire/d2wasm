// EXPECTED: 2
// EXPECTED: 4
int main() {
    int[5] arr = [1, 2, 3, 4, 5];
    foreach (val; arr) {
        if (val % 2 != 0) continue;
        __writeln(val);
    }
    return 0;
}
