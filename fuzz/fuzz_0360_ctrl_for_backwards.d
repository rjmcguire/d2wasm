// EXPECTED: 10
// EXPECTED: 9
// EXPECTED: 8
int main() {
    for (int i = 10; i >= 8; i--) {
        __writeln(i);
    }
    return 0;
}
