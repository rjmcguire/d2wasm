// EXPECTED: 15
// EXPECTED: 10
// EXPECTED: 50
int main() {
    double a = 10.0;
    a += 5.0;
    __writeln(cast(int)a);
    a -= 5.0;
    __writeln(cast(int)a);
    a *= 5.0;
    __writeln(cast(int)a);
    return 0;
}
