// EXPECTED: 1
// EXPECTED: 0
int main() {
    string a = "hello";
    string b = "world";
    if (a != b) __writeln(1); else __writeln(0);
    if (a != "hello") __writeln(1); else __writeln(0);
    return 0;
}
