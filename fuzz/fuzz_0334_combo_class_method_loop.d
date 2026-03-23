// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 10
class Accum {
    int total;
    this() { total = 0; }
    void add(int x) { total += x; }
    int get() { return total; }
}

int main() {
    auto a = new Accum();
    for (int i = 0; i < 5; i++) {
        a.add(i);
    }
    __writeln(a.get());
    return 0;
}
