// EXPECTED: 60
int multiply3(int a, int b, int c) {
    return a * b * c;
}

int main() {
    __writeln(multiply3(3, 4, 5));
    return 0;
}
