// EXPECTED: 2850
int main() {
    int s = 0;
    for (int i = 1; i <= 75; i++) s += i;
    __writeln(s);
    return 0;
}
