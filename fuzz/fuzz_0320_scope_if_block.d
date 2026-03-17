// EXPECTED: inside
// EXPECTED: outside
int main() {
    int x = 1;
    if (x == 1) {
        int y = 100;
        __writeln("inside");
    }
    __writeln("outside");
    return 0;
}
