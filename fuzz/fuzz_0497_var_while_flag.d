// EXPECTED: 5
int main() {
    int x = 0;
    bool done = false;
    while (!done) {
        x++;
        if (x >= 5) done = true;
    }
    __writeln(x);
    return 0;
}
