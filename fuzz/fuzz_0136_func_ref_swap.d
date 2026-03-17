// EXPECTED: 20
// EXPECTED: 10
void swap(ref int a, ref int b) {
    int tmp = a;
    a = b;
    b = tmp;
}

int main() {
    int x = 10;
    int y = 20;
    swap(x, y);
    __writeln(x);
    __writeln(y);
    return 0;
}
