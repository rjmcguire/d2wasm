// EXPECTED: 42
// EXPECTED: 42
int main() {
    int a = 42;
    long b = cast(long)a;
    __writeln(b);
    int c = cast(int)b;
    __writeln(c);
    return 0;
}
