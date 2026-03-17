// EXPECTED: 10
// EXPECTED: 20
// EXPECTED: 30
enum A = 10;
enum B = 20;
enum C = 30;

int main() {
    __writeln(A);
    __writeln(B);
    __writeln(C);
    return 0;
}
