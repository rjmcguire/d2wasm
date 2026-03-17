// EXPECTED: 6
int sumArr(int[3] arr) {
    int s = 0;
    foreach (v; arr) s += v;
    return s;
}

int main() {
    int[3] a = [1, 2, 3];
    __writeln(sumArr(a));
    return 0;
}
