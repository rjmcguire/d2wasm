// EXPECTED: 42
// EXPECTED: hello
int main() {
    auto x = 42;
    __writeln(x);
    auto s = "hello";
    __writeln(s);
    return 0;
}
