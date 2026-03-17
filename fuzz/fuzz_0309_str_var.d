// EXPECTED: test
// EXPECTED: test
int main() {
    string s = "test";
    __writeln(s);
    string t = s;
    __writeln(t);
    return 0;
}
