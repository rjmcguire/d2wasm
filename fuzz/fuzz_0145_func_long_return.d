// STATUS: bug — compile error
// EXPECTED: 5000000000
long bigVal() {
    return 5000000000;
}

int main() {
    __writeln(bigVal());
    return 0;
}
