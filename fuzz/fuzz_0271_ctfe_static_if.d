// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: yes
enum val = 10;

int main() {
    static if (val > 5) {
        __writeln("yes");
    } else {
        __writeln("no");
    }
    return 0;
}
