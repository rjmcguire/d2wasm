int sumTo(int n) {
    int sum = 0;
    int i = 1;
    while (i <= n) {
        sum = sum + i;
        i = i + 1;
    }
    return sum;
}

enum RESULT = sumTo(10);  // 1+2+...+10 = 55

int main() { return RESULT; }
