// EXPECTED: 5
int orDefault(int val, lazy int def) {
    if (val != 0) return val;
    return def;
}

int main() {
    __writeln(orDefault(5, 10));
    return 0;
}
