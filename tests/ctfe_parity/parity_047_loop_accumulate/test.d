int test() {
    // Sum of squares: 1^2 + 2^2 + ... + 10^2 = 385
    int sum = 0;
    int i = 1;
    while (i <= 10) {
        sum = sum + i * i;
        i = i + 1;
    }

    // Triangular number via for loop: 1+2+...+10 = 55
    int tri = 0;
    for (int j = 1; j <= 10; j = j + 1) {
        tri = tri + j;
    }

    return sum - tri;  // 385 - 55 = 330
}

enum RESULT = test();
int main() { return RESULT; }
