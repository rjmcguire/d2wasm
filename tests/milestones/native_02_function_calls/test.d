int add(int a, int b) {
    return a + b;
}

int double_add(int a, int b) {
    return add(a, b) + add(a, b);
}

int main() {
    return double_add(3, 4);
}
