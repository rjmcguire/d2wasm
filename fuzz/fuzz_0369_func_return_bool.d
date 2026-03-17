// EXPECTED: 1
bool isEven(int n) { return n % 2 == 0; }

int main() {
    if (isEven(42)) __writeln(1); else __writeln(0);
    return 0;
}
