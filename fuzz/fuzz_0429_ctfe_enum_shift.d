// EXPECTED: 256
enum A = 1;
enum B = A << 8;

int main() {
    __writeln(B);
    return 0;
}
