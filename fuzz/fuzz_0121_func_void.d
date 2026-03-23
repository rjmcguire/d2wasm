// STATUS: bug — void function not collected by emitter
// EXPECTED: hello
void greet() {
    __writeln("hello");
}

int main() {
    greet();
    return 0;
}
