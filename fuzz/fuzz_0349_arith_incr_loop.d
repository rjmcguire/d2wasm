// EXPECTED: 100
int main() {
    int x = 0;
    for (int i = 0; i < 100; i++) x++;
    __writeln(x);
    return 0;
}
