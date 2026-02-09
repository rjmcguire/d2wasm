int test() {
    int x = 10;
    x += 5;   // 15
    x -= 3;   // 12
    x *= 2;   // 24
    return x;
}

enum RESULT = test();
int main() { return RESULT; }
