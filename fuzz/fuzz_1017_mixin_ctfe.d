// STATUS: bug — wrong output
// EXPECTED: 10
enum code = "__writeln(10);";

int main() {
    mixin(code);
    return 0;
}
