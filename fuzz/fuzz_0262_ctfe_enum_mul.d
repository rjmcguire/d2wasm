// EXPECTED: 100
enum X = 10;
enum Y = X * X;

int main() {
    __writeln(Y);
    return 0;
}
