// EXPECTED: 42
// EXPECTED: 99
int g = 42;

int main() {
    __writeln(g);
    g = 99;
    __writeln(g);
    return 0;
}
