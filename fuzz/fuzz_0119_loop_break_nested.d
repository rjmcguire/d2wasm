// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: done
int main() {
    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 5; j++) {
            if (j == 1) break;
        }
        if (i == 3) break;
        __writeln(i);
    }
    __writeln("done");
    return 0;
}
