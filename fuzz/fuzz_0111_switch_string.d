// STATUS: maybeLater — switch not parsed
// EXPECTED: greeting
int main() {
    string s = "hello";
    switch (s) {
        case "hello":
            __writeln("greeting");
            break;
        case "bye":
            __writeln("farewell");
            break;
        default:
            __writeln("unknown");
            break;
    }
    return 0;
}
