// EXPECTED: -3
// EXPECTED: 5
int main() {
    double a = 3.5;
    __writeln(cast(int)(-a));
    double b = -5.0;
    __writeln(cast(int)(-b));
    return 0;
}
