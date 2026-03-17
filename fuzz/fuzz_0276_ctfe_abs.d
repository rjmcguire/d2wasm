// EXPECTED: 7
int myAbs(int x) {
    if (x < 0) return -x;
    return x;
}

enum result = myAbs(-7);

int main() {
    __writeln(result);
    return 0;
}
