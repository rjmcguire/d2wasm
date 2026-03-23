// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
class Num {
    int val;
    this(int v) { val = v; }
}

int main() {
    auto a = new Num(1);
    auto b = new Num(2);
    auto c = new Num(3);
    __writeln(a.val);
    __writeln(b.val);
    __writeln(c.val);
    return 0;
}
