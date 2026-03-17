// EXPECTED: 10
// EXPECTED: 20
int abs_val(int x) {
    return x >= 0 ? x : -x;
}

int main() {
    __writeln(abs_val(10));
    __writeln(abs_val(-20));
    return 0;
}
