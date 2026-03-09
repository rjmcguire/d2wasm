int main() {
    int[51] sieve;

    sieve[0] = 1;
    sieve[1] = 1;

    int i = 2;
    while (i * i <= 50) {
        if (sieve[i] == 0) {
            int j = i * i;
            while (j <= 50) {
                sieve[j] = 1;
                j = j + i;
            }
        }
        i = i + 1;
    }

    int count = 0;
    i = 2;
    while (i <= 50) {
        if (sieve[i] == 0) {
            count = count + 1;
        }
        i = i + 1;
    }
    return count;  // 15
}
