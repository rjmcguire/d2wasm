// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: done
int main() {
    int x = 5;
    if (x > 3) {
        __writeln(1);
        __writeln(2);
    }
    __writeln("done");
    return 0;
}
