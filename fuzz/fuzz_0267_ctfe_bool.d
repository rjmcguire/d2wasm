// EXPECTED: 1
// EXPECTED: 0
enum T = true;
enum F = false;

int main() {
    if (T) __writeln(1); else __writeln(0);
    if (F) __writeln(1); else __writeln(0);
    return 0;
}
