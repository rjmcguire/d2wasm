// EXPECTED: 8
int double_(int x) { return x * 2; }
int quad(int x) { return double_(double_(x)); }
enum r = quad(2);

int main() {
    __writeln(r);
    return 0;
}
