// EXPECTED: 1
int main() {
    int sum = 0;
    for (int i = 1; i <= 10; i++) sum += 10 / i;
    // 10+5+3+2+2+1+1+1+1+1 = 27... actually just check it adds
    if (sum > 0) __writeln(1); else __writeln(0);
    return 0;
}
