// EXPECTED: 2
// EXPECTED: 3
int main() {
    double a = 7.0;
    double b = 3.0;
    __writeln(cast(int)(a / b));
    __writeln(cast(int)(10.0 / 3.0));
    return 0;
}
