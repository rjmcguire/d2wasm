// EXPECTED: 4
int main() {
    int a = 12;
    int b = 8;
    while (a != b) {
        if (a > b) a -= b;
        else b -= a;
    }
    __writeln(a);
    return 0;
}
