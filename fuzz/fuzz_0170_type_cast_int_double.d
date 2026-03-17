// EXPECTED: 10
int main() {
    int a = 10;
    double b = cast(double)a;
    __writeln(cast(int)b);
    return 0;
}
