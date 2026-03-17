// EXPECTED: 4
// EXPECTED: 2
// EXPECTED: 25
int main() {
    float a = 10.0f;
    float b = 2.5f;
    __writeln(cast(int)(a / b));
    __writeln(cast(int)(a - 8.0f));
    __writeln(cast(int)(5.0f * 5.0f));
    return 0;
}
