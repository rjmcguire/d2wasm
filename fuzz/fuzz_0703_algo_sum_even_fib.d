// EXPECTED: 44
int main() {
    int a = 1;
    int b = 2;
    int s = 0;
    while (a <= 34) {
        if (a % 2 == 0) s += a;
        int c = a + b;
        a = b;
        b = c;
    }
    __writeln(s);
    return 0;
}
