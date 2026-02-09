int test() {
    int a = 1000000;
    int b = 2000000;
    return (a + b) / 1000;  // 3000
}

enum RESULT = test();
int main() { return RESULT; }
