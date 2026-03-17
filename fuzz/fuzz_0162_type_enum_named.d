// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
enum Color { red, green, blue }

int main() {
    Color c = Color.red;
    __writeln(cast(int)c);
    c = Color.green;
    __writeln(cast(int)c);
    c = Color.blue;
    __writeln(cast(int)c);
    return 0;
}
