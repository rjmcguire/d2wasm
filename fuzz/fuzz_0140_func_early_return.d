// EXPECTED: -1
// EXPECTED: 0
// EXPECTED: 1
int clamp(int x) {
    if (x < 0) return -1;
    if (x > 0) return 1;
    return 0;
}

int main() {
    __writeln(clamp(-50));
    __writeln(clamp(0));
    __writeln(clamp(50));
    return 0;
}
