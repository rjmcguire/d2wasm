int test() {
    int a = -10;
    int b = -32;
    return a + b;  // -42
}

enum RESULT = test();
int main() { return RESULT; }
