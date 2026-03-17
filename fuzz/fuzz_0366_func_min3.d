// EXPECTED: 5
int min3(int a, int b, int c) {
    int m = a;
    if (b < m) m = b;
    if (c < m) m = c;
    return m;
}

int main() {
    __writeln(min3(5, 10, 15));
    return 0;
}
