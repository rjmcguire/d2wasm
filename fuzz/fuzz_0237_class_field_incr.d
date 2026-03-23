// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 3
class Counter {
    int count;
    this() { count = 0; }
    void inc() { count++; }
    int get() { return count; }
}

int main() {
    auto c = new Counter();
    c.inc();
    c.inc();
    c.inc();
    __writeln(c.get());
    return 0;
}
