// STATUS: bug — compile error
// EXPECTED: 104
int main() {
    string s = "hello";
    // s[0] should be 'h' = 104
    __writeln(cast(int)s[0]);
    return 0;
}
