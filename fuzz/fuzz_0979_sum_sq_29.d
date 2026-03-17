// EXPECTED: 8555
int main() {
    int s = 0;
    for (int i = 1; i <= 29; i++) s += i * i;
    __writeln(s);
    return 0;
}
