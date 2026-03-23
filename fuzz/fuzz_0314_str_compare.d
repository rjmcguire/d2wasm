// STATUS: bug — wrong output
// EXPECTED: 1
// EXPECTED: 0
int main() {
    string a = "hello";
    string b = "hello";
    if (a == b) __writeln(1); else __writeln(0);
    string c = "world";
    if (a == c) __writeln(1); else __writeln(0);
    return 0;
}
