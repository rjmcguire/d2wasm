// EXPECTED: 3
int main() {
    int[5] a = [0, 1, 0, 0, 2];
    int c = 0;
    foreach (v; a) if (v == 0) c++;
    __writeln(c);
    return 0;
}
