// EXPECTED: 100
enum TEN = 10;
enum HUNDRED = TEN * TEN;

int main() {
    __writeln(HUNDRED);
    return 0;
}
