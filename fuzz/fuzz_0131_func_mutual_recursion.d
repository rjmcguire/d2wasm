// EXPECTED: 1
// EXPECTED: 0
bool isEven(int n);
bool isOdd(int n);

bool isEven(int n) {
    if (n == 0) return true;
    return isOdd(n - 1);
}

bool isOdd(int n) {
    if (n == 0) return false;
    return isEven(n - 1);
}

int main() {
    if (isEven(4)) __writeln(1); else __writeln(0);
    if (isOdd(4)) __writeln(1); else __writeln(0);
    return 0;
}
