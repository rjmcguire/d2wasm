// EXPECTED: 5
// EXPECTED: 5
// EXPECTED: 5
int five() {
    return 5;
}

int main() {
    __writeln(five());
    __writeln(five());
    __writeln(five());
    return 0;
}
