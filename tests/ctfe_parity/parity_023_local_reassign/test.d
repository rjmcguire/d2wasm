int test() {
    int x = 10;
    x = x + 5;
    x = x * 2;
    return x;  // (10+5)*2 = 30
}

enum RESULT = test();
int main() { return RESULT; }
