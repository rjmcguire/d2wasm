// EXPECTED: helloworld
int main() {
    string a = "hello";
    string b = "world";
    string c = a ~ b;
    __writeln(c);
    return 0;
}
