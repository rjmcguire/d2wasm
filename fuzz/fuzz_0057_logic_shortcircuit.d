// EXPECTED: 10
// EXPECTED: 10
int main() {
    int x = 10;
    // Short-circuit: second operand not evaluated
    if (false && (x = 20) > 0) {}
    __writeln(x);
    // Short-circuit: second operand not evaluated
    if (true || (x = 30) > 0) {}
    __writeln(x);
    return 0;
}
