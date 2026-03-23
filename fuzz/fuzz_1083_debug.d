// STATUS: bug — compile error
// EXPECTED: release
debug {
    enum mode = "debug";
} else {
    enum mode = "release";
}

int main() {
    __writeln(mode);
    return 0;
}
