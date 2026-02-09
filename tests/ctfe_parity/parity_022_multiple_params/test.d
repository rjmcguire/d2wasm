int add4(int a, int b, int c, int d) {
    return a + b + c + d;
}

int test() {
    return add4(10, 20, 30, 40);  // 100
}

enum RESULT = test();
int main() { return RESULT; }
