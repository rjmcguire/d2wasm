int test() {
    int sum = 0;
    for (int i = 1; i <= 10; i = i + 1) {
        sum = sum + i;
    }
    return sum;  // 1+2+...+10 = 55
}

enum RESULT = test();
int main() { return RESULT; }
