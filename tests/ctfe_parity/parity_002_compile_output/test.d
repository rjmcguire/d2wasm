// CTFE Parity Test: Compile output
// Both backends should print during CTFE

int printValue(int x) {
    __writeln(x);
    return x;
}

enum RESULT = printValue(42);

int main() {
    return RESULT;
}
