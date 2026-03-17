// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: fizz
// EXPECTED: 4
// EXPECTED: buzz
int main() {
    for (int i = 1; i <= 5; i++) {
        if (i % 3 == 0) __writeln("fizz");
        else if (i % 5 == 0) __writeln("buzz");
        else __writeln(i);
    }
    return 0;
}
