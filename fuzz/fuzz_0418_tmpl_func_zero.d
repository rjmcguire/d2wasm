// EXPECTED: 0
T zero(T)() { return cast(T)0; }

int main() {
    __writeln(zero!int());
    return 0;
}
