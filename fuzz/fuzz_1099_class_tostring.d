// STATUS: bug — compile error
// EXPECTED: 5
class Num {
    int val;
    this(int v) { val = v; }
    override string toString() { return __itos(val); }
}

int main() {
    auto n = new Num(5);
    __writeln(n.toString());
    return 0;
}
