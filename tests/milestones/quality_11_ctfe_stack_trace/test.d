int inner(int x) {
    return x / 0;
}

int outer(int x) {
    return inner(x);
}

enum value = outer(5);

int result() {
    return value;
}
