int fib(int n) {
    if (n <= 1) {
        return n;
    }
    int a = 0;
    int b = 1;
    int i = 2;
    while (i <= n) {
        int tmp = a + b;
        a = b;
        b = tmp;
        i = i + 1;
    }
    return b;
}

int test() {
    // fib(10) = 55, fib(15) = 610
    return fib(10) + fib(15);  // 55 + 610 = 665
}

enum RESULT = test();
int main() { return RESULT; }
