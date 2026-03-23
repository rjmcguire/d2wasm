// STATUS: bug — void function not collected by emitter
// EXPECTED: hi
void say(string msg) {
    __writeln(msg);
}

int main() {
    say("hi");
    return 0;
}
