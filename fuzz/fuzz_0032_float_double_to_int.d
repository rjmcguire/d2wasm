// EXPECTED: 3
// EXPECTED: -3
// EXPECTED: 7
int main() {
    double a = 3.7;
    __writeln(cast(int)a);
    double b = -3.7;
    __writeln(cast(int)b);
    double c = 7.99;
    __writeln(cast(int)c);
    return 0;
}
