// EXPECTED: -1
// EXPECTED: 0
// EXPECTED: -256
int main() {
    __writeln(~0);
    __writeln(~(-1));
    __writeln(~255);
    return 0;
}
