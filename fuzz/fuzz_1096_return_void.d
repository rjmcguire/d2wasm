// EXPECTED: before
// EXPECTED: after
void earlyReturn(bool flag) {
    __writeln("before");
    if (flag) return;
    __writeln("skipped");
}

int main() {
    earlyReturn(true);
    __writeln("after");
    return 0;
}
