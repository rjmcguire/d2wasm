// EXPECTED: 20
// EXPECTED: 10
int main() {
    int a = 10;
    int b = 20;
    int t = a; a = b; b = t;
    __writeln(a);
    __writeln(b);
    return 0;
}
