// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: big
enum VAL = 100;

int main() {
    static if (VAL > 50) __writeln("big");
    else __writeln("small");
    return 0;
}
