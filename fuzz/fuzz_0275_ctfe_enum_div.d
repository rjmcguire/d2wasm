// EXPECTED: 5
enum A = 100;
enum B = A / 20;

int main() {
    __writeln(B);
    return 0;
}
