// EXPECTED: 15
enum A = 5;
enum B = 10;
enum C = A + B;

int main() {
    __writeln(C);
    return 0;
}
