// EXPECTED: 1000000
// EXPECTED: 500000
int main() {
    double a = 1000000.0;
    __writeln(cast(int)a);
    __writeln(cast(int)(a / 2.0));
    return 0;
}
