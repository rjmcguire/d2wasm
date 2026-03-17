// EXPECTED: 20
// EXPECTED: 10
void swap(T)(ref T a, ref T b) {
    T tmp = a;
    a = b;
    b = tmp;
}

int main() {
    int x = 10;
    int y = 20;
    swap!int(x, y);
    __writeln(x);
    __writeln(y);
    return 0;
}
