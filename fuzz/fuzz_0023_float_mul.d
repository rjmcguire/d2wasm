// EXPECTED: 6
// EXPECTED: 0
// EXPECTED: 25
int main() {
    double a = 2.0;
    double b = 3.0;
    __writeln(cast(int)(a * b));
    __writeln(cast(int)(0.0 * 999.0));
    __writeln(cast(int)(5.0 * 5.0));
    return 0;
}
