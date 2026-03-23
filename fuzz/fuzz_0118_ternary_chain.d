// STATUS: bug — wrong output
// EXPECTED: big
int main() {
    int x = 100;
    __writeln(x < 10 ? "small" : (x < 50 ? "medium" : "big"));
    return 0;
}
