// EXPECTED: 3
int myMin(int a, int b) { return a < b ? a : b; }
enum m = myMin(3, 7);

int main() {
    __writeln(m);
    return 0;
}
