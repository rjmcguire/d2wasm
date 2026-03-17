// EXPECTED: 1
int collatz(int n) {
    int steps = 0;
    while (n != 1) {
        if (n % 2 == 0) n = n / 2;
        else n = 3 * n + 1;
        steps++;
    }
    return steps;
}

int main() {
    // collatz(1) = 0 steps
    __writeln(collatz(2));
    return 0;
}
