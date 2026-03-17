// EXPECTED: 6
int digitalRoot(int n) {
    while (n >= 10) {
        int s = 0;
        while (n > 0) { s += n % 10; n /= 10; }
        n = s;
    }
    return n;
}

int main() {
    __writeln(digitalRoot(123));
    return 0;
}
