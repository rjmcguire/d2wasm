// EXPECTED: 50
int mulN(int N)(int x) {
    return x * N;
}

int main() {
    __writeln(mulN!10(5));
    return 0;
}
