int isEven(int n);
int isOdd(int n);

int isEven(int n) {
    if (n == 0) { return 1; }
    return isOdd(n - 1);
}

int isOdd(int n) {
    if (n == 0) { return 0; }
    return isEven(n - 1);
}

int main() {
    int sum = 0;
    sum = sum + isEven(0);   // 1
    sum = sum + isEven(4);   // 1
    sum = sum + isEven(7);   // 0
    sum = sum + isOdd(3);    // 1
    sum = sum + isOdd(6);    // 0
    sum = sum + isOdd(11);   // 1
    return sum;  // 4
}
