// EXPECTED: 5050
int sumTo(int n) {
    int s = 0;
    for (int i = 1; i <= n; i++) s += i;
    return s;
}
enum s = sumTo(100);

int main() {
    __writeln(s);
    return 0;
}
