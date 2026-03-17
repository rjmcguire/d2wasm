// EXPECTED: 10
// EXPECTED: 5
int main() {
    int a = 10;
    int b = 5;
    int max = a > b ? a : b;
    __writeln(max);
    int min = a < b ? a : b;
    __writeln(min);
    return 0;
}
