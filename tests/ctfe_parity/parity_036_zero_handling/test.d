int test() {
    int a = 0;
    int b = 42;
    int c = a + b;      // 42
    int d = b * a;      // 0
    int e = b - b;      // 0
    return c + d + e;   // 42
}

enum RESULT = test();
int main() { return RESULT; }
