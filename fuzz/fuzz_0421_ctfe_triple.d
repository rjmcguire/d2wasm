// EXPECTED: 30
int triple(int x) { return x * 3; }
enum r = triple(10);

int main() {
    __writeln(r);
    return 0;
}
