// EXPECTED: 15
// EXPECTED: 1
int main() {
    auto a = 3;
    auto b = 5;
    auto c = a * b;
    __writeln(c);
    auto d = a < b;
    if (d) __writeln(1); else __writeln(0);
    return 0;
}
