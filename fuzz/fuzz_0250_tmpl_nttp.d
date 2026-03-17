// EXPECTED: 15
int addN(int N)(int x) {
    return x + N;
}

int main() {
    __writeln(addN!10(5));
    return 0;
}
