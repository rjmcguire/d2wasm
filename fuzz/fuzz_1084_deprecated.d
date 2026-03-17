// EXPECTED: 42
deprecated("use newFunc instead")
int oldFunc() { return 42; }

int newFunc() { return 42; }

int main() {
    __writeln(newFunc());
    return 0;
}
