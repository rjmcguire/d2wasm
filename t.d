int apply(int delegate(int) dg, int x) {
    return dg(x);
}

int main() {
    int y = 10;
    auto dg = (int x) => x + y;
    y = 20;
    return apply(dg, 5);
}
