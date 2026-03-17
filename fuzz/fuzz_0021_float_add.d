// EXPECTED: 3
// EXPECTED: 0
int main() {
    double a = 1.5;
    double b = 1.5;
    __writeln(cast(int)(a + b));
    __writeln(cast(int)(0.0 + 0.0));
    return 0;
}
