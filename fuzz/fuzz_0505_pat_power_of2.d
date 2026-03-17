// EXPECTED: 1
// EXPECTED: 1
// EXPECTED: 0
bool isPow2(int n) { return n > 0 && (n & (n - 1)) == 0; }

int main() {
    if (isPow2(16)) __writeln(1); else __writeln(0);
    if (isPow2(1)) __writeln(1); else __writeln(0);
    if (isPow2(6)) __writeln(1); else __writeln(0);
    return 0;
}
