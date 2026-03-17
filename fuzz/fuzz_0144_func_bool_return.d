// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 1
bool isPositive(int x) {
    return x > 0;
}

int main() {
    if (isPositive(5)) __writeln(1); else __writeln(0);
    if (isPositive(-5)) __writeln(1); else __writeln(0);
    if (isPositive(1)) __writeln(1); else __writeln(0);
    return 0;
}
