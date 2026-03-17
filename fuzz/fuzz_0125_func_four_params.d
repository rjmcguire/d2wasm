// EXPECTED: 10
int sum4(int a, int b, int c, int d) {
    return a + b + c + d;
}

int main() {
    __writeln(sum4(1, 2, 3, 4));
    return 0;
}
