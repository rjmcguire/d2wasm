int test() {
    return 17 % 5 + 100 % 7;  // 2 + 2 = 4
}

enum RESULT = test();
int main() { return RESULT; }
