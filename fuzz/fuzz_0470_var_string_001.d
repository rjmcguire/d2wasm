// EXPECTED: abc
int main() {
    string s = "a" ~ "b" ~ "c";
    __writeln(s);
    return 0;
}
