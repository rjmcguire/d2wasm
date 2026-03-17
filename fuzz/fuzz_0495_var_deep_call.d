// EXPECTED: 11
int a(int x) { return x + 1; }
int b(int x) { return a(x) + 1; }
int c(int x) { return b(x) + 1; }
int d(int x) { return c(x) + 1; }

int main() {
    __writeln(d(7));
    return 0;
}
