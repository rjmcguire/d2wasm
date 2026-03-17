// EXPECTED: 144
int sq(int x) { return x * x; }
enum s = sq(12);

int main() {
    __writeln(s);
    return 0;
}
