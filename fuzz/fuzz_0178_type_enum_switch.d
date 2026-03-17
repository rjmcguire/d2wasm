// EXPECTED: red
enum Color { red, green, blue }

void printColor(Color c) {
    switch (c) {
        case Color.red: __writeln("red"); break;
        case Color.green: __writeln("green"); break;
        case Color.blue: __writeln("blue"); break;
        default: break;
    }
}

int main() {
    printColor(Color.red);
    return 0;
}
