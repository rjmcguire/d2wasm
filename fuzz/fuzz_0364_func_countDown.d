// EXPECTED: 3
// EXPECTED: 2
// EXPECTED: 1
// EXPECTED: 0
void countDown(int n) {
    while (n >= 0) { __writeln(n); n--; }
}

int main() {
    countDown(3);
    return 0;
}
