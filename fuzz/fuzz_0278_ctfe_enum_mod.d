// EXPECTED: 3
enum A = 13;
enum B = A % 5;

int main() {
    __writeln(B);
    return 0;
}
