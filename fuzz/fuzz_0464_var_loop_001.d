// EXPECTED: 45
int main() {
    int s = 0;
    for (int i = 0; i < 10; i++) s += i;
    __writeln(s);
    return 0;
}
