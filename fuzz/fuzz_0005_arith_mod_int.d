// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 3
// EXPECTED: -1
int main() {
    __writeln(7 % 3);
    __writeln(9 % 3);
    __writeln(3 % 5);
    __writeln(-7 % 3);
    return 0;
}
