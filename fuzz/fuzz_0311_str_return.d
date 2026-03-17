// EXPECTED: hello
string greet() {
    return "hello";
}

int main() {
    __writeln(greet());
    return 0;
}
