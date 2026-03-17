// EXPECTED: even
// EXPECTED: odd
string parity(int n) {
    return n % 2 == 0 ? "even" : "odd";
}

int main() {
    __writeln(parity(4));
    __writeln(parity(7));
    return 0;
}
