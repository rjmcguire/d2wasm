// EXPECTED: 10
int main() {
    int s = 0;
    foreach (i; 1 .. 5) s += i;
    __writeln(s);
    return 0;
}
