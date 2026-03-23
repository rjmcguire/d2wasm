// STATUS: bug — wrong output
// EXPECTED: 45
struct Acc {
    int total;
    void add(int x) { total += x; }
    int get() { return total; }
}

int main() {
    Acc a;
    a.total = 0;
    for (int i = 0; i < 10; i++) a.add(i);
    __writeln(a.get());
    return 0;
}
