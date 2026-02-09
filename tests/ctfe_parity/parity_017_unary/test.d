int test() {
    int a = 42;
    int b = -a;      // -42
    int c = ~0;      // -1 (all bits set)
    return b + c;    // -42 + (-1) = -43
}

enum RESULT = test();

int main() { return RESULT; }
