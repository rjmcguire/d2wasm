// Milestone 77: D-to-D function calls in CTFE

int helper() {
    return 42;
}

int addTen(int x) {
    return x + 10;
}

int test() {
    int a = helper();
    int b = addTen(a);
    return b;  // 42 + 10 = 52
}

enum result = test();

int main() {
    return result;
}
