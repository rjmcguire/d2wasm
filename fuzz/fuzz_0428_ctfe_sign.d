// EXPECTED: -1
int sign(int x) {
    if (x > 0) return 1;
    if (x < 0) return -1;
    return 0;
}
enum s = sign(-42);

int main() {
    __writeln(s);
    return 0;
}
