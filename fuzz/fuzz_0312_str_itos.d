// EXPECTED: val=42
int main() {
    int x = 42;
    __writeln("val=" ~ __itos(x));
    return 0;
}
