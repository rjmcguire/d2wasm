// EXPECTED: 1
void foo(ref int x) {
    static if (__traits(isRef, x)) __writeln(1);
    else __writeln(0);
}

int main() {
    int a = 5;
    foo(a);
    return 0;
}
