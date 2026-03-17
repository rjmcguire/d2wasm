// EXPECTED: 15
enum A = 5;
enum B = 10;

int main() {
    int x = A + B;
    __writeln(x);
    return 0;
}
