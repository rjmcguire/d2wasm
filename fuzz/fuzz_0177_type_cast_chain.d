// EXPECTED: 42
int main() {
    int a = 42;
    long b = cast(long)a;
    short c = cast(short)b;
    int d = cast(int)c;
    __writeln(d);
    return 0;
}
