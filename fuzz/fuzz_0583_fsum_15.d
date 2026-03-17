// EXPECTED: 120
int main() {
    int s = 0;
    for (int i = 1; i <= 15; i++) s += i;
    __writeln(s);
    return 0;
}
