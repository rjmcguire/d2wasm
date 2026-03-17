// EXPECTED: 2870
int main() {
    int s = 0;
    for (int i = 1; i <= 20; i++) s += i * i;
    __writeln(s);
    return 0;
}
