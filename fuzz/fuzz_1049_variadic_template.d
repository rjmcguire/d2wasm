// STATUS: maybeLater — foreach not parsed
// EXPECTED: 6
// Tests variadic templates (probably not implemented)
int sum(T...)(T args) {
    int s = 0;
    foreach (a; args) s += a;
    return s;
}

int main() {
    __writeln(sum(1, 2, 3));
    return 0;
}
