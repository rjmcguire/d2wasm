// EXPECTED: 30
int mulN(int N)(int x) { return x * N; }

int main() {
    __writeln(mulN!3(10));
    return 0;
}
