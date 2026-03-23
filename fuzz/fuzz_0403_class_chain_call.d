// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 15
class Acc {
    int total;
    this() { total = 0; }
    void add(int x) { total += x; }
}

int main() {
    auto a = new Acc();
    a.add(5);
    a.add(10);
    __writeln(a.total);
    return 0;
}
