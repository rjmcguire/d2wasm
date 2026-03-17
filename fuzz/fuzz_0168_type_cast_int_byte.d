// EXPECTED: 42
// EXPECTED: 42
int main() {
    int a = 42;
    byte b = cast(byte)a;
    __writeln(b);
    int c = cast(int)b;
    __writeln(c);
    return 0;
}
