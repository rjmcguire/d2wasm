// EXPECTED: 60
struct V { int x; }

int main() {
    V[3] arr;
    arr[0] = V(10); arr[1] = V(20); arr[2] = V(30);
    int s = 0;
    for (int i = 0; i < 3; i++) s += arr[i].x;
    __writeln(s);
    return 0;
}
