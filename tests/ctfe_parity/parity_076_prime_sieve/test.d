int countPrimes() {
    int[51] sieve;  // 0 = prime candidate, 1 = composite

    // Mark 0 and 1 as non-prime
    sieve[0] = 1;
    sieve[1] = 1;

    int i = 2;
    while (i * i <= 50) {
        if (sieve[i] == 0) {
            // Mark multiples
            int j = i * i;
            while (j <= 50) {
                sieve[j] = 1;
                j = j + i;
            }
        }
        i = i + 1;
    }

    // Count primes
    int count = 0;
    i = 2;
    while (i <= 50) {
        if (sieve[i] == 0) {
            count = count + 1;
        }
        i = i + 1;
    }
    return count;
    // Primes <= 50: 2,3,5,7,11,13,17,19,23,29,31,37,41,43,47 = 15
}

int test() { return countPrimes(); }
enum RESULT = test();
int main() { return RESULT; }
