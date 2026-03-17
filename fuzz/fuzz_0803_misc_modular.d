// EXPECTED: 3
int mod(int a, int m) { return ((a % m) + m) % m; }

int main() {
    __writeln(mod(-7, 5));
    return 0;
}
