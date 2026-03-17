// EXPECTED: 1
// EXPECTED: 2
int main() {
    int[5] arr = [1, 2, 3, 4, 5];
    foreach (val; arr) {
        if (val == 3) break;
        __writeln(val);
    }
    return 0;
}
