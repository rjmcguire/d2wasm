// EXPECTED: 3
// EXPECTED: 7
int main() {
    auto a = 3;
    auto b = a + 4;
    __writeln(a);
    __writeln(b);
    return 0;
}
