// Sum of 0 + 1 + 2 + ... + (n-1)
int sum_to(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        sum = sum + i;
    }
    return sum;
}
