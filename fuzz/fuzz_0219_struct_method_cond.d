// EXPECTED: 1
// EXPECTED: 0
struct Range {
    int lo;
    int hi;

    bool contains(int x) {
        return x >= lo && x <= hi;
    }
}

int main() {
    auto r = Range(1, 10);
    if (r.contains(5)) __writeln(1); else __writeln(0);
    if (r.contains(15)) __writeln(1); else __writeln(0);
    return 0;
}
