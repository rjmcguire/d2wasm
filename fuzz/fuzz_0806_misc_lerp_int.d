// EXPECTED: 50
int main() {
    int a = 0;
    int b = 100;
    int t = 50;
    __writeln(a + (b - a) * t / 100);
    return 0;
}
