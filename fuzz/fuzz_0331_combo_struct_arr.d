// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
struct Val { int x; }

int main() {
    Val[3] arr;
    arr[0] = Val(1);
    arr[1] = Val(2);
    arr[2] = Val(3);
    for (int i = 0; i < 3; i++) {
        __writeln(arr[i].x);
    }
    return 0;
}
