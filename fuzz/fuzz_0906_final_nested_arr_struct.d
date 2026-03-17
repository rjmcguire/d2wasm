// EXPECTED: 6
struct V { int x; }

int sum(V[3] arr) {
    int s = 0;
    for (int i = 0; i < 3; i++) s += arr[i].x;
    return s;
}

int main() {
    V[3] arr;
    arr[0] = V(1); arr[1] = V(2); arr[2] = V(3);
    __writeln(sum(arr));
    return 0;
}
