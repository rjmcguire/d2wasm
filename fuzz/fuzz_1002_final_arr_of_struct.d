// STATUS: bug — compile error
// EXPECTED: 10
// EXPECTED: 40
// EXPECTED: 90
struct S {
    int x;
    int sq() { return x * x; }
}

int main() {
    S[3] arr;
    arr[0] = S(1);
    arr[1] = S(2);
    arr[2] = S(3);
    for (int i = 0; i < 3; i++) {
        __writeln(arr[i].sq() * 10);
    }
    return 0;
}
