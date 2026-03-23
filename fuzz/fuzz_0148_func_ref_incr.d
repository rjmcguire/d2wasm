// STATUS: bug — compile error
// EXPECTED: 3
void increment(ref int x) {
    x++;
}

int main() {
    int val = 0;
    increment(val);
    increment(val);
    increment(val);
    __writeln(val);
    return 0;
}
