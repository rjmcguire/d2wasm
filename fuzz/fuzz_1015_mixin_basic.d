// EXPECTED: hello
int main() {
    mixin("__writeln(\"hello\");");
    return 0;
}
