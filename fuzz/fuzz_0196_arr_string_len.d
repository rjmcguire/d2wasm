// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 11
int main() {
    string a = "";
    __writeln(a.length);
    string b = "x";
    __writeln(b.length);
    string c = "hello world";
    __writeln(c.length);
    return 0;
}
