// EXPECTED: 20
int val(bool b) {
    if (b) return 10;
    return 20;
}

int main() {
    __writeln(val(false));
    return 0;
}
