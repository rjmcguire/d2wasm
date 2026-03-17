// EXPECTED: 30
int main() {
    int s = 0;
    for (int i = 0; i <= 10; i++) if (i % 2 == 0) s += i;
    __writeln(s);
    return 0;
}
