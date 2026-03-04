int main() {
    // While loop with double condition
    double x = 0.0;
    int count = 0;
    while (x < 5.0) {
        x = x + 0.5;
        count = count + 1;
    }
    // count should be 10

    // For loop with cast
    double sum = 0.0;
    for (int i = 1; i <= 4; i++) {
        sum = sum + cast(double) i;
    }
    // sum = 10.0

    return count + cast(int) sum; // 20
}
