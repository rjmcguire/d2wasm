// EXPECTED: 0
// EXPECTED: 5
int main() {
    double a = 0.0;
    __writeln(cast(int)a);
    __writeln(cast(int)(a + 5.0));
    return 0;
}
