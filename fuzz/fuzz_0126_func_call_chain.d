// STATUS: bug — wrong output
// EXPECTED: 9
int double_(int x) {
    return x * 2;
}

int inc(int x) {
    return x + 1;
}

int main() {
    __writeln(double_(inc(double_(2))));
    return 0;
}
