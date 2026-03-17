// EXPECTED: 20
// EXPECTED: 10
int main() {
    int a = 10;
    int b = 20;
    a = a ^ b;
    b = a ^ b;
    a = a ^ b;
    __writeln(a);
    __writeln(b);
    return 0;
}
