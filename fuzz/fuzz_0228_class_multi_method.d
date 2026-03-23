// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 3
// EXPECTED: 5
class Counter {
    int val;

    this(int v) { val = v; }

    int get() { return val; }

    void add(int n) { val += n; }
}

int main() {
    auto c = new Counter(0);
    c.add(3);
    __writeln(c.get());
    c.add(2);
    __writeln(c.get());
    return 0;
}
