// EXPECTED: 5
// EXPECTED: 6
int main() {
    float a = 2.0f;
    float b = 3.0f;
    __writeln(cast(int)(a + b));
    __writeln(cast(int)(a * b));
    return 0;
}
