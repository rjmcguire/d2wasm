// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: true
enum flag = true;

int main() {
    static if (flag) __writeln("true");
    else __writeln("false");
    return 0;
}
