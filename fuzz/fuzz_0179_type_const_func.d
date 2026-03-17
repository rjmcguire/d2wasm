// EXPECTED: 10
int doubleVal(const int x) {
    return x * 2;
}

int main() {
    __writeln(doubleVal(5));
    return 0;
}
