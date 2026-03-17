// EXPECTED: 1
// EXPECTED: 0
bool inRange(int x, int lo, int hi) {
    return x >= lo && x <= hi;
}

int main() {
    if (inRange(5, 1, 10)) __writeln(1); else __writeln(0);
    if (inRange(15, 1, 10)) __writeln(1); else __writeln(0);
    return 0;
}
