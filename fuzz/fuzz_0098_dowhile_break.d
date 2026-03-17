// EXPECTED: 0
// EXPECTED: 1
int main() {
    int i = 0;
    do {
        if (i == 2) break;
        __writeln(i);
        i++;
    } while (i < 10);
    return 0;
}
