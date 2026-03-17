// EXPECTED: 5
int main() {
    int a = 3;
    int b = 8;
    int d = a - b;
    if (d < 0) d = -d;
    __writeln(d);
    return 0;
}
