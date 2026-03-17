// EXPECTED: 3
// EXPECTED: -7
int main() {
    double a = 3.99;
    __writeln(cast(int)a);
    double b = -7.5;
    __writeln(cast(int)b);
    return 0;
}
