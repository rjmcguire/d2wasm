int classify(int n) {
    if (n < 0) {
        if (n < -100) {
            return 1;
        } else {
            if (n < -10) {
                return 2;
            } else {
                return 3;
            }
        }
    } else {
        if (n == 0) {
            return 4;
        } else {
            if (n > 100) {
                return 5;
            } else {
                return 6;
            }
        }
    }
}

int test() {
    int sum = 0;
    sum = sum + classify(-200);  // 1
    sum = sum + classify(-50);   // 2
    sum = sum + classify(-5);    // 3
    sum = sum + classify(0);     // 4
    sum = sum + classify(200);   // 5
    sum = sum + classify(42);    // 6
    return sum;  // 1+2+3+4+5+6 = 21
}

enum RESULT = test();
int main() { return RESULT; }
