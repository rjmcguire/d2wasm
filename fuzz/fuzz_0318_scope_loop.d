// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
int main() {
    for (int i = 0; i < 3; i++) {
        int x = i;
        __writeln(x);
    }
    return 0;
}
