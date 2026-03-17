// EXPECTED: 12345
int main() {
    string s = "";
    for (int i = 1; i <= 5; i++) {
        s = s ~ __itos(i);
    }
    __writeln(s);
    return 0;
}
