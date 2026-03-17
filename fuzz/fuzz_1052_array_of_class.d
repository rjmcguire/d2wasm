// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
class Num {
    int v;
    this(int v) { this.v = v; }
}

int main() {
    Num[3] arr;
    for (int i = 0; i < 3; i++) {
        arr[i] = new Num(i);
    }
    for (int i = 0; i < 3; i++) {
        __writeln(arr[i].v);
    }
    return 0;
}
