// STATUS: maybeLater — do-while not parsed
// EXPECTED: once
int main() {
    do {
        __writeln("once");
    } while (false);
    return 0;
}
