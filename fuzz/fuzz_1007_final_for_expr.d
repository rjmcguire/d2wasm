// EXPECTED: 1023
int main() {
    int s = 0;
    for (int i = 0; i < 10; i++) {
        s += 1 << i;
    }
    __writeln(s);
    return 0;
}
