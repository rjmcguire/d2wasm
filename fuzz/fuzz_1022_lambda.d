// EXPECTED: 12
int main() {
    auto mul = (int a, int b) => a * b;
    __writeln(mul(3, 4));
    return 0;
}
