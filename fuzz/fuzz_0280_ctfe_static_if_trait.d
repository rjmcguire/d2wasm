// EXPECTED: yes
int main() {
    static if (__traits(isArithmetic, int)) {
        __writeln("yes");
    } else {
        __writeln("no");
    }
    return 0;
}
