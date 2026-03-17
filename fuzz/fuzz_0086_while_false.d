// EXPECTED: done
int main() {
    while (false) {
        __writeln("never");
    }
    __writeln("done");
    return 0;
}
