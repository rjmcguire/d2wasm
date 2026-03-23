// STATUS: maybeLater — switch not parsed
// EXPECTED: green
enum Color { red, green, blue }

string colorName(Color c) {
    switch (c) {
        case Color.red: return "red";
        case Color.green: return "green";
        case Color.blue: return "blue";
        default: return "unknown";
    }
}

int main() {
    __writeln(colorName(Color.green));
    return 0;
}
