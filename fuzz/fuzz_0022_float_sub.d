// EXPECTED: 1
// EXPECTED: 0
int main() {
    double a = 3.5;
    double b = 2.5;
    __writeln(cast(int)(a - b));
    __writeln(cast(int)(5.0 - 5.0));
    return 0;
}
