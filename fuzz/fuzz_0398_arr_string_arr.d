// EXPECTED: hello
// EXPECTED: world
int main() {
    string[2] s = ["hello", "world"];
    __writeln(s[0]);
    __writeln(s[1]);
    return 0;
}
