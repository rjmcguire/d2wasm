// EXPECTED: 0
int main() {
    int x = 50;
    for (int i = 0; i < 50; i++) x--;
    __writeln(x);
    return 0;
}
