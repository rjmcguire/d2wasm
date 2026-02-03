struct Adder {
    int base;
    int add(int n) { return base + n; }
}

int main() {
    Adder a = Adder(10);
    return a.add(5);
}
