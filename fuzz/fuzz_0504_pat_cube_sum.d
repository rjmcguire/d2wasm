// EXPECTED: 36
int main() {
    int s = 0;
    for (int i = 1; i <= 3; i++) s += i * i * i;
    __writeln(s);
    return 0;
}
