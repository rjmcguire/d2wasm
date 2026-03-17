// EXPECTED: 3628800
int main() {
    int p = 1;
    for (int i = 1; i <= 10; i++) p *= i;
    __writeln(p);
    return 0;
}
