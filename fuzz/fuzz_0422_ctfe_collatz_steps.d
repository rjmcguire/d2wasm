// EXPECTED: 8
int collatz(int n) {
    int s = 0;
    while (n != 1) {
        if (n % 2 == 0) n /= 2;
        else n = 3 * n + 1;
        s++;
    }
    return s;
}
enum steps = collatz(6);

int main() {
    __writeln(steps);
    return 0;
}
