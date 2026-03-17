// EXPECTED: else
int main() {
    if (false) __writeln("if");
    else __writeln("else");
    return 0;
}
