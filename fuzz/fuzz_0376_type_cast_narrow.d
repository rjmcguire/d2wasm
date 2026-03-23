// STATUS: bug — wrong output
// EXPECTED: 44
int main() {
    int a = 300;
    byte b = cast(byte)a;
    __writeln(b);
    return 0;
}
