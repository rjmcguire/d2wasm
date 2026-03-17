// EXPECTED: 1
// EXPECTED: 1
// EXPECTED: 0
int main() {
    int a = 5;
    int b = 10;
    int c = 15;
    if ((a < b) && (b < c) && (a < c)) __writeln(1); else __writeln(0);
    if ((a == 5) || (b == 5) || (c == 5)) __writeln(1); else __writeln(0);
    if ((a > b) || (b > c) || (c < a)) __writeln(1); else __writeln(0);
    return 0;
}
