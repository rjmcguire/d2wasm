// EXPECTED: 99
@system int rawVal() {
    return 99;
}

int main() {
    __writeln(rawVal());
    return 0;
}
