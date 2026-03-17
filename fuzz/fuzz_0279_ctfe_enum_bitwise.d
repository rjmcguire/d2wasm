// EXPECTED: 15
enum A = 0xFF;
enum B = A & 0x0F;

int main() {
    __writeln(B);
    return 0;
}
