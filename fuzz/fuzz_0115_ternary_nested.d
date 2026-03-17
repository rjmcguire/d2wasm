// EXPECTED: zero
int main() {
    int x = 0;
    __writeln(x > 0 ? "positive" : (x < 0 ? "negative" : "zero"));
    return 0;
}
