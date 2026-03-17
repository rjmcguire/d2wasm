// EXPECTED: 1024
int power(int b, int e) {
    int r = 1;
    for (int i = 0; i < e; i++) r *= b;
    return r;
}

int main() {
    __writeln(power(2, 10));
    return 0;
}
