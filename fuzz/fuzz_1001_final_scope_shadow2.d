// EXPECTED: outer
// EXPECTED: inner
// EXPECTED: outer
int main() {
    string s = "outer";
    __writeln(s);
    {
        string s = "inner";
        __writeln(s);
    }
    __writeln(s);
    return 0;
}
