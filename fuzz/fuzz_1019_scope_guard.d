// STATUS: maybeLater — scope_guard_statement not implemented
// EXPECTED: hello
// EXPECTED: cleanup
// Tests scope(exit)
int main() {
    scope(exit) __writeln("cleanup");
    __writeln("hello");
    return 0;
}
