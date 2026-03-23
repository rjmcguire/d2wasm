// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: no
enum val = 3;

int main() {
    static if (val > 5) {
        __writeln("yes");
    } else {
        __writeln("no");
    }
    return 0;
}
