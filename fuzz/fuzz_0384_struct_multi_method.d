// STATUS: bug — compile error
// EXPECTED: 5
// EXPECTED: 0
struct Counter {
    int val;
    void inc() { val++; }
    void dec() { val--; }
    int get() { return val; }
}

int main() {
    Counter c;
    c.val = 0;
    c.inc(); c.inc(); c.inc(); c.inc(); c.inc();
    __writeln(c.get());
    c.dec(); c.dec(); c.dec(); c.dec(); c.dec();
    __writeln(c.get());
    return 0;
}
