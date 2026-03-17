// EXPECTED: 42
string makeCode() {
    return "int x = 42; __writeln(x);";
}

int main() {
    mixin(makeCode());
    return 0;
}
