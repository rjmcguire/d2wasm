// EXPECTED: 42
int foo();

int main() {
    __writeln(foo());
    return 0;
}

int foo() {
    return 42;
}
