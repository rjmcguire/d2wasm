// EXPECTED: 7
// EXPECTED: 12
int main() {
    int a = 5;
    double b = 2.5;
    __writeln(cast(int)(cast(double)a + b));
    __writeln(cast(int)(cast(double)a * b));
    return 0;
}
