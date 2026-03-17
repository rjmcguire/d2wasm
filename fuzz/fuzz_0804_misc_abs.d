// EXPECTED: 42
int abs(int x) { return x < 0 ? -x : x; }

int main() {
    __writeln(abs(-42));
    return 0;
}
