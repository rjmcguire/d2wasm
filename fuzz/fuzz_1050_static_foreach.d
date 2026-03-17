// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
int main() {
    static foreach (i; 0 .. 3) {
        __writeln(i);
    }
    return 0;
}
