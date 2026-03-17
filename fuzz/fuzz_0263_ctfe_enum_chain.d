// EXPECTED: 6
enum A = 1;
enum B = A + 1;
enum C = B + 1;
enum D = A + B + C;

int main() {
    __writeln(D);
    return 0;
}
