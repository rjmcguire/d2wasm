// EXPECTED: 15
void addTo(ref int x, int y) { x += y; }

int main() {
    int a = 10;
    addTo(a, 5);
    __writeln(a);
    return 0;
}
