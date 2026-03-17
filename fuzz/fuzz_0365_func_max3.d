// EXPECTED: 30
int max3(int a, int b, int c) {
    int m = a;
    if (b > m) m = b;
    if (c > m) m = c;
    return m;
}

int main() {
    __writeln(max3(10, 30, 20));
    return 0;
}
