// STATUS: bug — compile error
// EXPECTED: 42
union IntOrFloat {
    int i;
    float f;
}

int main() {
    IntOrFloat u;
    u.i = 42;
    __writeln(u.i);
    return 0;
}
