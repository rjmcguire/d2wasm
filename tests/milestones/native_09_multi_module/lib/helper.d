module helper;

int add(int a, int b) {
    return a + b;
}

int triple(int x) {
    return add(x, add(x, x));
}
