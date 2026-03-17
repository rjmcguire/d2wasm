// EXPECTED: 10
// EXPECTED: 20
int counter = 0;

void bump(int n) {
    counter += n;
}

int main() {
    bump(10);
    __writeln(counter);
    bump(10);
    __writeln(counter);
    return 0;
}
