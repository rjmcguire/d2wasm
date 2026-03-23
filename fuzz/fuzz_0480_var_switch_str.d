// STATUS: maybeLater — switch not parsed
// EXPECTED: matched
int main() {
    string s = "foo";
    switch (s) {
        case "foo": __writeln("matched"); break;
        default: __writeln("no"); break;
    }
    return 0;
}
