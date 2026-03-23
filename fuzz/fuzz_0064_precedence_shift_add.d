// STATUS: bug — wrong output
// EXPECTED: 6
// EXPECTED: 16
int main() {
    __writeln(1 + 1 << 1 + 1);
    __writeln(1 << 4);
    return 0;
}
