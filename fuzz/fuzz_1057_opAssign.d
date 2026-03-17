// EXPECTED: 42
struct Val {
    int x;

    void opAssign(int v) {
        x = v;
    }
}

int main() {
    Val v;
    v = 42;
    __writeln(v.x);
    return 0;
}
