// EXPECTED: 8
// EXPECTED: 2
int main() {
    int a = 1;
    a <<= 3;
    __writeln(a);
    a >>= 2;
    __writeln(a);
    return 0;
}
