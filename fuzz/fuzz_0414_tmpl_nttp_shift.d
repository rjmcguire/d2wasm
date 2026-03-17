// EXPECTED: 256
int shiftN(int N)(int x) { return x << N; }

int main() {
    __writeln(shiftN!8(1));
    return 0;
}
