// STATUS: bug — wrong output
// EXPECTED: x
int main() {
    int x = 42;
    __writeln(__traits(identifier, x));
    return 0;
}
