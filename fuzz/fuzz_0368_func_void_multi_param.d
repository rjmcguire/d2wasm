// EXPECTED: 3-7
void printSum(int a, int b, int c) {
    __writeln(__itos(a) ~ "-" ~ __itos(b + c));
}

int main() {
    printSum(3, 3, 4);
    return 0;
}
