// EXPECTED: 240
int main() {
    int x = 0xFF;
    __writeln(x & 0xF0);
    return 0;
}
