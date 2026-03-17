// EXPECTED: 10
int clamp(int x, int lo, int hi) {
    if (x < lo) return lo;
    if (x > hi) return hi;
    return x;
}

int main() {
    __writeln(clamp(15, 0, 10));
    return 0;
}
