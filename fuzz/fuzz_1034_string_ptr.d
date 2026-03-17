// EXPECTED: 5
int main() {
    string s = "hello";
    auto p = s.ptr;
    __writeln(s.length);
    return 0;
}
