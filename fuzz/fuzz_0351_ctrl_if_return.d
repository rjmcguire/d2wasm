// EXPECTED: 10
int val(bool b) {
    if (b) return 10;
    return 20;
}

int main() {
    __writeln(val(true));
    return 0;
}
