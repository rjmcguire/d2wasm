// EXPECTED: 11
// EXPECTED: 7
int main() {
    double x = 2.0 + 3.0 * 3.0;
    __writeln(cast(int)x);
    double y = (2.0 + 3.0) * 3.0 - 8.0;
    __writeln(cast(int)y);
    return 0;
}
