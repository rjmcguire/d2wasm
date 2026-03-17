// EXPECTED: inner
int main() {
    int x = 5;
    if (x > 0) {
        if (x > 3) {
            __writeln("inner");
        }
    }
    return 0;
}
