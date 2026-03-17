// EXPECTED: pos
// EXPECTED: zero
// EXPECTED: neg
int sign(int x) {
    if (x > 0) return 1;
    else if (x == 0) return 0;
    else return -1;
}

int main() {
    if (sign(5) == 1) __writeln("pos");
    if (sign(0) == 0) __writeln("zero");
    if (sign(-3) == -1) __writeln("neg");
    return 0;
}
