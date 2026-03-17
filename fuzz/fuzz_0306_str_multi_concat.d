// EXPECTED: abcdef
int main() {
    string a = "ab";
    string b = "cd";
    string c = "ef";
    __writeln(a ~ b ~ c);
    return 0;
}
