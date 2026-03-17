// EXPECTED: 10
void doubleIt(ref int x) {
    x *= 2;
}

int main() {
    int a = 5;
    doubleIt(a);
    __writeln(a);
    return 0;
}
