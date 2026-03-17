// EXPECTED: 10
// EXPECTED: 3
void divmod(int a, int b, out int quot, out int rem) {
    quot = a / b;
    rem = a % b;
}

int main() {
    int q;
    int r;
    divmod(33, 3, q, r);
    __writeln(q + r);
    __writeln(r);
    return 0;
}
