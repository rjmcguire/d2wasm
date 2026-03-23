// STATUS: bug — compile error
// EXPECTED: 25
int square(int x) { return x * x; }

int main() {
    auto fp = &square;
    __writeln(fp(5));
    return 0;
}
