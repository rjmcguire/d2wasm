// EXPECTED: D
int main() {
    int score = 65;
    if (score >= 90) __writeln("A");
    else if (score >= 80) __writeln("B");
    else if (score >= 70) __writeln("C");
    else if (score >= 60) __writeln("D");
    else __writeln("F");
    return 0;
}
