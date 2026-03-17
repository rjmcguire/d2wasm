// EXPECTED: 30
struct MyArr {
    int[5] data;

    int opIndex(int i) {
        return data[i];
    }
}

int main() {
    MyArr a;
    a.data = [10, 20, 30, 40, 50];
    __writeln(a[2]);
    return 0;
}
