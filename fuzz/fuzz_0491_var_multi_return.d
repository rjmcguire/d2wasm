// EXPECTED: a
// EXPECTED: b
// EXPECTED: c
string letter(int i) {
    if (i == 0) return "a";
    if (i == 1) return "b";
    return "c";
}

int main() {
    __writeln(letter(0));
    __writeln(letter(1));
    __writeln(letter(2));
    return 0;
}
