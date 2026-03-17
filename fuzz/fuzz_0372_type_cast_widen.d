// EXPECTED: 127
int main() {
    byte a = 127;
    int b = cast(int)a;
    __writeln(b);
    return 0;
}
