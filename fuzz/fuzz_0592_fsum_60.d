// EXPECTED: 1830
int main() {
    int s = 0;
    for (int i = 1; i <= 60; i++) s += i;
    __writeln(s);
    return 0;
}
