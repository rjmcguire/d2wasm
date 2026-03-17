// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 1
int main() {
    bool[3] arr = [true, false, true];
    if (arr[0]) __writeln(1); else __writeln(0);
    if (arr[1]) __writeln(1); else __writeln(0);
    if (arr[2]) __writeln(1); else __writeln(0);
    return 0;
}
