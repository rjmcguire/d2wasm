// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 10
// EXPECTED: 20
class Pair {
    int a;
    int b;

    this(int a, int b) {
        this.a = a;
        this.b = b;
    }
}

int main() {
    auto p = new Pair(10, 20);
    __writeln(p.a);
    __writeln(p.b);
    return 0;
}
