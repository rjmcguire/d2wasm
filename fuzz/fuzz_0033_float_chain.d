// EXPECTED: 10
int main() {
    double a = 1.0;
    double b = 2.0;
    double c = 3.0;
    double d = 4.0;
    __writeln(cast(int)(a + b + c + d));
    return 0;
}
