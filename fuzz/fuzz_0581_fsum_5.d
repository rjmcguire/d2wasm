// EXPECTED: 15
int main() {
    int s = 0;
    for (int i = 1; i <= 5; i++) s += i;
    __writeln(s);
    return 0;
}
