// EXPECTED: 25
// EXPECTED: 20
// EXPECTED: 9
int main() {
    __writeln((2 + 3) * 5);
    __writeln((10 - 6) * 5);
    __writeln((1 + 2) * (1 + 2));
    return 0;
}
