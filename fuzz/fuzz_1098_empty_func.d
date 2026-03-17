// EXPECTED: done
void noop() {}

int main() {
    noop();
    noop();
    noop();
    __writeln("done");
    return 0;
}
