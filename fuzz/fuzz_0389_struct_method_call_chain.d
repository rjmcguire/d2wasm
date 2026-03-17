// EXPECTED: 6
struct Num {
    int val;
    int doubled() { return val * 2; }
    int tripled() { return val * 3; }
}

int main() {
    auto n = Num(2);
    __writeln(n.tripled());
    return 0;
}
