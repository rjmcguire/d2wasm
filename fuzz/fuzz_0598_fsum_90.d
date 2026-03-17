// EXPECTED: 4095
int main() {
    int s = 0;
    for (int i = 1; i <= 90; i++) s += i;
    __writeln(s);
    return 0;
}
